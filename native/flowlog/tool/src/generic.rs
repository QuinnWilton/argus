//! The generic engine: any FlowLog program argus can host, run without
//! compiling it. `argus-flowlog-tool serve` plans the program when it
//! starts, as `generate` would, and evaluates the plan with one row type on
//! Differential Dataflow, behind the same host and protocol as a compiled
//! engine (`host`).
//!
//! A compiled engine instantiates Differential Dataflow's operators once
//! per row type, which is minutes of LLVM for a large program; this one
//! instantiates them once, here. A row is a short vector of `u32` slots:
//! a number's bits, an interned symbol's key, a `bool`, or an interned
//! tuple's id. The planner's types decide what a slot means where it is
//! compared, computed with, or written out.
//!
//! Every input argus hosts is `mutable`, so every collection here carries
//! signed weights, and every relation is a set (each head is deduplicated).
//! Results are the compiled engine's; only `ord`, which numbers symbols in
//! the order they were first seen, may differ, as it may between two runs
//! of a compiled engine.

use std::collections::HashMap;
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::sync::mpsc;
use std::thread::JoinHandle;

use flowlog_common::Config;
use flowlog_common::SourceMap;
use flowlog_parser::AggregationOperator;
use flowlog_parser::ArithmeticOperator;
use flowlog_parser::BuiltinOperator;
use flowlog_parser::ComparisonOperator;
use flowlog_parser::Constant;
use flowlog_parser::DataType;
use flowlog_parser::Program;
use flowlog_planner::planner::ArithmeticArgument;
use flowlog_planner::planner::FactorArgument;
use flowlog_planner::planner::ProgramPlanner;
use flowlog_planner::planner::Transformation;
use flowlog_planner::planner::TransformationArgument;
use flowlog_planner::planner::TransformationFlow;
use flowlog_runtime::differential_dataflow::AsCollection;
use flowlog_runtime::differential_dataflow::VecCollection;
use flowlog_runtime::differential_dataflow::input::Input as _;
use flowlog_runtime::differential_dataflow::input::InputSession;
use flowlog_runtime::differential_dataflow::lattice::Lattice;
use flowlog_runtime::differential_dataflow::operators::arrange::Arranged;
use flowlog_runtime::differential_dataflow::operators::arrange::TraceAgent;
use flowlog_runtime::differential_dataflow::operators::iterate::Variable;
use flowlog_runtime::differential_dataflow::trace::implementations::ValSpine;
use flowlog_runtime::differential_dataflow::trace::wrappers::enter::TraceEnter;
use flowlog_runtime::intern;
use flowlog_runtime::lasso::Key;
use flowlog_runtime::lasso::Spur;
use flowlog_runtime::regex::Regex;
use flowlog_runtime::timely;
use flowlog_runtime::timely::dataflow::Scope;
use flowlog_runtime::timely::dataflow::operators::ToStream;
use flowlog_runtime::timely::dataflow::operators::probe::Handle as ProbeHandle;
use flowlog_runtime::timely::order::Product;
use flowlog_runtime::timely::progress::Timestamp;
use flowlog_runtime::timely::progress::timestamp::Refines;
use serde::Deserialize;
use serde::Serialize;
use smallvec::SmallVec;

use crate::host::Changes;
use crate::host::Column;
use crate::host::Dataflow;
use crate::host::Fields;
use crate::host::Relation;

/// A row's slots, inline up to four: most keys are one or two columns,
/// and every arranged update holds a key and a value. Four used a tenth
/// less memory than six on argus's largest programs, as fast.
pub type Row = SmallVec<[u32; 4]>;
/// Every collection's data: a key and a value. A row collection's key is
/// empty, and so is a key-only collection's value.
type Kv = (Row, Row);
type Diff = i32;
/// Where the workers push an output's changes for the host to drain.
type Sink = Arc<Mutex<Vec<(Row, Diff)>>>;
type Epoch = u32;
type LoopTime = Product<Epoch, u32>;

// =============================================================================
// Values
// =============================================================================

/// What a slot holds.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
enum Ty {
    Num,
    Str,
    Bool,
    Tuple(Arc<[Ty]>),
}

impl Ty {
    fn of(data_type: &DataType) -> Result<Self, String> {
        Ok(match data_type {
            DataType::Int32 => Ty::Num,
            DataType::String => Ty::Str,
            DataType::Bool => Ty::Bool,
            DataType::FixedTuple(fields) => Ty::Tuple(
                fields
                    .iter()
                    .map(Ty::of)
                    .collect::<Result<Vec<_>, _>>()?
                    .into(),
            ),
            other => return Err(format!("the generic engine has no `{other}` columns")),
        })
    }
}

fn number(slot: u32) -> i32 {
    slot as i32
}

fn slot_of_number(n: i32) -> u32 {
    n as u32
}

fn symbol(slot: u32) -> &'static str {
    intern::resolve(Spur::try_from_usize(slot as usize).expect("a symbol slot is an interned key"))
}

fn slot_of_symbol(text: &str) -> u32 {
    intern::intern(text).into_usize() as u32
}

/// Tuples, interned like symbols: a tuple slot is its id here.
#[derive(Default)]
struct Tuples {
    ids: HashMap<Box<[u32]>, u32>,
    fields: Vec<Box<[u32]>>,
}

fn tuples() -> &'static Mutex<Tuples> {
    static TUPLES: OnceLock<Mutex<Tuples>> = OnceLock::new();
    TUPLES.get_or_init(Mutex::default)
}

fn slot_of_tuple(fields: &[u32]) -> u32 {
    let mut tuples = tuples().lock().expect("the tuple table");
    if let Some(&id) = tuples.ids.get(fields) {
        return id;
    }
    let id = u32::try_from(tuples.fields.len()).expect("fewer than 2^32 tuples");
    tuples.fields.push(fields.into());
    tuples.ids.insert(fields.into(), id);
    id
}

fn tuple_field(slot: u32, index: usize) -> u32 {
    tuples().lock().expect("the tuple table").fields[slot as usize][index]
}

/// A constant as the plan keeps it: by value, for a symbol's slot is its
/// key in this process's interner, which a cached plan cannot carry.
#[derive(Clone, Debug, Serialize, Deserialize)]
enum Lit {
    Num(i32),
    Sym(String),
    Bool(bool),
}

impl Lit {
    fn of(c: &Constant) -> Result<Self, String> {
        let text = c.text();
        Ok(match c.ty() {
            DataType::Int32 => Lit::Num(
                text.parse()
                    .map_err(|_| format!("`{text}` is not a 32-bit number"))?,
            ),
            DataType::String => Lit::Sym(text.to_string()),
            DataType::Bool => Lit::Bool(text == "True"),
            other => return Err(format!("the generic engine has no `{other}` constants")),
        })
    }

    fn slot(&self) -> u32 {
        match self {
            Lit::Num(n) => slot_of_number(*n),
            Lit::Sym(text) => slot_of_symbol(text),
            Lit::Bool(b) => u32::from(*b),
        }
    }
}

/// A constant and its slot, interned on first use.
#[derive(Debug, Serialize, Deserialize)]
struct Const {
    lit: Lit,
    #[serde(skip)]
    slot: OnceLock<u32>,
}

impl Const {
    fn new(lit: Lit) -> Self {
        Const {
            lit,
            slot: OnceLock::new(),
        }
    }

    fn slot(&self) -> u32 {
        *self.slot.get_or_init(|| self.lit.slot())
    }
}

/// `a` against `b`, both of type `ty`, as the compiled engine orders them:
/// numbers by value, symbols by their text, tuples field by field.
fn order(ty: &Ty, a: u32, b: u32) -> std::cmp::Ordering {
    match ty {
        Ty::Num => number(a).cmp(&number(b)),
        Ty::Str => symbol(a).cmp(symbol(b)),
        Ty::Bool => a.cmp(&b),
        Ty::Tuple(fields) => {
            for (index, field) in fields.iter().enumerate() {
                let ordering = order(field, tuple_field(a, index), tuple_field(b, index));
                if ordering.is_ne() {
                    return ordering;
                }
            }
            std::cmp::Ordering::Equal
        }
    }
}

// =============================================================================
// Expressions
// =============================================================================

/// Where an expression reads a column: the data's key or value, or a join's
/// left or right value. A row's columns are its value.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
enum Slot {
    Key(usize),
    Value(usize),
    Left(usize),
    Right(usize),
}

/// The columns an expression reads, as one step's input hands them over.
struct Ctx<'a> {
    key: &'a [u32],
    value: &'a [u32],
    left: &'a [u32],
    right: &'a [u32],
}

impl Ctx<'_> {
    fn read(&self, slot: Slot) -> u32 {
        match slot {
            Slot::Key(i) => self.key[i],
            Slot::Value(i) => self.value[i],
            Slot::Left(i) => self.left[i],
            Slot::Right(i) => self.right[i],
        }
    }
}

/// The input shape a step's column references resolve against.
#[derive(Clone, Copy, Serialize, Deserialize)]
enum Shape {
    /// A row: `KV((_, i))` is column `i`, whichever flag it carries.
    Row,
    /// A key-value pair: `KV((true, i))` is key column `i`, as is an
    /// antijoin's `Jn((_, true, i))`.
    Kv,
    /// A join: `Jn((_, true, i))` is the shared key's column `i`, and
    /// `Jn((left, false, i))` that side's value column `i`.
    Join,
}

/// The column types of a step's input, by its shape.
struct Types<'a> {
    shape: Shape,
    key: &'a [Ty],
    value: &'a [Ty],
    right_value: &'a [Ty],
}

impl Types<'_> {
    fn slot(&self, arg: &TransformationArgument) -> Result<(Slot, Ty), String> {
        let pick = |types: &[Ty], i: usize, slot: Slot| {
            types.get(i).cloned().map(|ty| (slot, ty)).ok_or_else(|| {
                format!(
                    "planner error: column {i} of a collection with {}",
                    types.len()
                )
            })
        };
        match (self.shape, *arg) {
            (Shape::Row, TransformationArgument::KV((_, i))) => pick(self.value, i, Slot::Value(i)),
            // An antijoin's flow names the surviving side's columns as a
            // join's would; which side it names does not matter.
            (
                Shape::Kv,
                TransformationArgument::KV((true, i)) | TransformationArgument::Jn((_, true, i)),
            ) => pick(self.key, i, Slot::Key(i)),
            (
                Shape::Kv,
                TransformationArgument::KV((false, i)) | TransformationArgument::Jn((_, false, i)),
            ) => pick(self.value, i, Slot::Value(i)),
            (Shape::Join, TransformationArgument::Jn((_, true, i))) => {
                pick(self.key, i, Slot::Key(i))
            }
            (Shape::Join, TransformationArgument::Jn((true, false, i))) => {
                pick(self.value, i, Slot::Left(i))
            }
            (Shape::Join, TransformationArgument::Jn((false, false, i))) => {
                pick(self.right_value, i, Slot::Right(i))
            }
            (_, other) => Err(format!(
                "planner error: {other} does not address this step's input"
            )),
        }
    }
}

/// FlowLog's arithmetic operators, as a plan keeps them.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
enum Arith {
    Plus,
    Minus,
    Multiply,
    Divide,
    Modulo,
    Power,
    BitAnd,
    BitOr,
    BitXor,
    ShiftLeft,
    ShiftRight,
    ShiftRightUnsigned,
}

impl Arith {
    fn of(op: &ArithmeticOperator) -> Self {
        match op {
            ArithmeticOperator::Plus => Arith::Plus,
            ArithmeticOperator::Minus => Arith::Minus,
            ArithmeticOperator::Multiply => Arith::Multiply,
            ArithmeticOperator::Divide => Arith::Divide,
            ArithmeticOperator::Modulo => Arith::Modulo,
            ArithmeticOperator::Power => Arith::Power,
            ArithmeticOperator::BitAnd => Arith::BitAnd,
            ArithmeticOperator::BitOr => Arith::BitOr,
            ArithmeticOperator::BitXor => Arith::BitXor,
            ArithmeticOperator::ShiftLeft => Arith::ShiftLeft,
            ArithmeticOperator::ShiftRight => Arith::ShiftRight,
            ArithmeticOperator::ShiftRightUnsigned => Arith::ShiftRightUnsigned,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
enum Expr {
    Col(Slot),
    Const(Const),
    /// Numbers folded left to right, as FlowLog evaluates them.
    Fold(Box<Expr>, Vec<(Arith, Expr)>),
    Strlen(Box<Expr>),
    Substr(Box<Expr>, Box<Expr>, Box<Expr>),
    Ord(Box<Expr>),
    ToString(Box<Expr>, Ty),
    ToNumber(Box<Expr>),
    Cat(Vec<Expr>),
    Tuple(Vec<Expr>),
    Proj(Box<Expr>, usize),
}

fn compile(arg: &ArithmeticArgument, types: &Types<'_>) -> Result<(Expr, Ty), String> {
    let (init, ty) = compile_factor(&arg.init, types)?;
    if arg.rest.is_empty() {
        return Ok((init, ty));
    }
    let mut steps = Vec::with_capacity(arg.rest.len());
    for (op, factor) in &arg.rest {
        let (expr, operand) = compile_factor(factor, types)?;
        if operand != Ty::Num {
            return Err(format!(
                "the generic engine computes `{op:?}` on numbers only"
            ));
        }
        steps.push((Arith::of(op), expr));
    }
    if ty != Ty::Num {
        return Err("the generic engine computes arithmetic on numbers only".into());
    }
    Ok((Expr::Fold(Box::new(init), steps), Ty::Num))
}

fn compile_factor(factor: &FactorArgument, types: &Types<'_>) -> Result<(Expr, Ty), String> {
    let boxed = |arg: &ArithmeticArgument| compile(arg, types).map(|(e, t)| (Box::new(e), t));
    Ok(match factor {
        FactorArgument::Var(arg) => {
            let (slot, ty) = types.slot(arg)?;
            (Expr::Col(slot), ty)
        }
        FactorArgument::Const(c) => (Expr::Const(Const::new(Lit::of(c)?)), Ty::of(c.ty())?),
        FactorArgument::Group(inner) => compile(inner, types)?,
        FactorArgument::Builtin { op, args } => match (op, args.as_slice()) {
            (BuiltinOperator::Strlen, [s]) => (Expr::Strlen(boxed(s)?.0), Ty::Num),
            (BuiltinOperator::Substr, [s, start, len]) => (
                Expr::Substr(boxed(s)?.0, boxed(start)?.0, boxed(len)?.0),
                Ty::Str,
            ),
            (BuiltinOperator::Ord, [s]) => (Expr::Ord(boxed(s)?.0), Ty::Num),
            (BuiltinOperator::ToString, [n]) => {
                let (expr, ty) = boxed(n)?;
                (Expr::ToString(expr, ty), Ty::Str)
            }
            (BuiltinOperator::ToNumber, [s]) => (Expr::ToNumber(boxed(s)?.0), Ty::Num),
            (BuiltinOperator::Cat, [a, b]) => {
                let mut parts = Vec::new();
                cat_parts(a, types, &mut parts)?;
                cat_parts(b, types, &mut parts)?;
                (Expr::Cat(parts), Ty::Str)
            }
            (op, args) => return Err(format!("planner error: {op} with {} arguments", args.len())),
        },
        FactorArgument::Tuple { fields } => {
            let compiled = fields
                .iter()
                .map(|f| compile(f, types))
                .collect::<Result<Vec<_>, _>>()?;
            let tys: Vec<Ty> = compiled.iter().map(|(_, t)| t.clone()).collect();
            (
                Expr::Tuple(compiled.into_iter().map(|(e, _)| e).collect()),
                Ty::Tuple(tys.into()),
            )
        }
        FactorArgument::TupleProj { tuple, index } => {
            let (expr, ty) = boxed(tuple)?;
            let Ty::Tuple(fields) = ty else {
                return Err("planner error: a projection of a value that is not a tuple".into());
            };
            let field = fields.get(*index).cloned().ok_or_else(|| {
                format!("planner error: field {index} of a {}-tuple", fields.len())
            })?;
            (Expr::Proj(expr, *index), field)
        }
        FactorArgument::FnCall { name, .. } => {
            return Err(format!(
                "the generic engine cannot call the user-defined function `{name}`"
            ));
        }
    })
}

/// A `cat` argument's parts: a nested `cat` contributes its own, flattened.
fn cat_parts(
    arg: &ArithmeticArgument,
    types: &Types<'_>,
    parts: &mut Vec<Expr>,
) -> Result<(), String> {
    if arg.rest.is_empty()
        && let FactorArgument::Builtin {
            op: BuiltinOperator::Cat,
            args,
        } = &arg.init
    {
        for inner in args {
            cat_parts(inner, types, parts)?;
        }
        return Ok(());
    }
    let (expr, ty) = compile(arg, types)?;
    if ty != Ty::Str {
        return Err("planner error: a `cat` argument that is not a string".into());
    }
    parts.push(expr);
    Ok(())
}

fn arith(op: Arith, a: i32, b: i32) -> i32 {
    use flowlog_runtime::arith;
    match op {
        Arith::Plus => a.wrapping_add(b),
        Arith::Minus => a.wrapping_sub(b),
        Arith::Multiply => a.wrapping_mul(b),
        // A compiled engine's division by zero, or of the least number by
        // -1, panics and aborts the engine; so does this one.
        Arith::Divide => a / b,
        Arith::Modulo => a % b,
        Arith::BitAnd => a & b,
        Arith::BitOr => a | b,
        Arith::BitXor => a ^ b,
        Arith::Power => arith::pow(a, b),
        Arith::ShiftLeft => arith::bshl(a, b),
        Arith::ShiftRight => arith::bshr(a, b),
        Arith::ShiftRightUnsigned => arith::bshru(a, b),
    }
}

impl Expr {
    fn eval(&self, ctx: &Ctx<'_>) -> u32 {
        match self {
            Expr::Col(slot) => ctx.read(*slot),
            Expr::Const(c) => c.slot(),
            Expr::Fold(init, steps) => {
                let mut acc = number(init.eval(ctx));
                for (op, operand) in steps {
                    acc = arith(*op, acc, number(operand.eval(ctx)));
                }
                slot_of_number(acc)
            }
            Expr::Strlen(s) => slot_of_number(symbol(s.eval(ctx)).chars().count() as i32),
            Expr::Substr(s, start, len) => {
                // As the compiled engine casts them: a negative index is huge.
                let start = number(start.eval(ctx)) as usize;
                let len = number(len.eval(ctx)) as usize;
                let text: String = symbol(s.eval(ctx)).chars().skip(start).take(len).collect();
                slot_of_symbol(&text)
            }
            Expr::Ord(s) => {
                let key = Spur::try_from_usize(s.eval(ctx) as usize).expect("an interned key");
                slot_of_number(key.into_inner().get() as i32)
            }
            Expr::ToString(n, ty) => {
                let value = n.eval(ctx);
                let text = match ty {
                    Ty::Num => number(value).to_string(),
                    Ty::Bool => (value != 0).to_string(),
                    Ty::Str => symbol(value).to_string(),
                    Ty::Tuple(_) => unreachable!("typecheck rejects to_string of a tuple"),
                };
                slot_of_symbol(&text)
            }
            Expr::ToNumber(s) => slot_of_number(symbol(s.eval(ctx)).parse::<i32>().unwrap_or(0)),
            Expr::Cat(parts) => {
                let mut text = String::new();
                for part in parts {
                    text.push_str(symbol(part.eval(ctx)));
                }
                slot_of_symbol(&text)
            }
            Expr::Tuple(fields) => {
                let slots: Row = fields.iter().map(|f| f.eval(ctx)).collect();
                slot_of_tuple(&slots)
            }
            Expr::Proj(tuple, index) => tuple_field(tuple.eval(ctx), *index),
        }
    }
}

/// An equality or an ordering.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
enum Cmp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

/// A literal pattern, compiled on first use: one that does not compile
/// matches nothing.
#[derive(Debug, Serialize, Deserialize)]
struct Pattern {
    text: String,
    #[serde(skip)]
    regex: OnceLock<Option<Regex>>,
}

impl Pattern {
    fn regex(&self) -> Option<&Regex> {
        self.regex
            .get_or_init(|| Regex::new(&format!("^(?:{})$", self.text)).ok())
            .as_ref()
    }
}

/// A step's filter.
#[derive(Debug, Serialize, Deserialize)]
enum Pred {
    /// An equality or ordering between two values of type `Ty`.
    Compare(Cmp, Ty, Expr, Expr),
    /// `right` contains `left`'s text, or does not.
    Contains(bool, Expr, Expr),
    /// `right` matches a literal pattern whole, or does not.
    MatchLiteral(bool, Pattern, Expr),
    /// `right` matches `left`'s pattern whole, or does not.
    Match(bool, Expr, Expr),
}

fn compile_compare(
    op: &ComparisonOperator,
    left: &ArithmeticArgument,
    right: &ArithmeticArgument,
    types: &Types<'_>,
) -> Result<Pred, String> {
    let (l, ty) = compile(left, types)?;
    let (r, _) = compile(right, types)?;
    Ok(match op {
        ComparisonOperator::Contains { negated } => Pred::Contains(*negated, l, r),
        ComparisonOperator::Match { negated } => match (&left.init, left.rest.is_empty()) {
            (FactorArgument::Const(c), true) if c.ty() == &DataType::String => {
                let pattern = Pattern {
                    text: c.text().to_string(),
                    regex: OnceLock::new(),
                };
                Pred::MatchLiteral(*negated, pattern, r)
            }
            _ => Pred::Match(*negated, l, r),
        },
        ComparisonOperator::Equal => Pred::Compare(Cmp::Eq, ty, l, r),
        ComparisonOperator::NotEqual => Pred::Compare(Cmp::Ne, ty, l, r),
        ComparisonOperator::LessThan => Pred::Compare(Cmp::Lt, ty, l, r),
        ComparisonOperator::LessEqualThan => Pred::Compare(Cmp::Le, ty, l, r),
        ComparisonOperator::GreaterThan => Pred::Compare(Cmp::Gt, ty, l, r),
        ComparisonOperator::GreaterEqualThan => Pred::Compare(Cmp::Ge, ty, l, r),
    })
}

impl Pred {
    fn holds(&self, ctx: &Ctx<'_>) -> bool {
        use std::cmp::Ordering::*;
        match self {
            Pred::Compare(op, ty, l, r) => {
                let (a, b) = (l.eval(ctx), r.eval(ctx));
                match op {
                    Cmp::Eq => a == b,
                    Cmp::Ne => a != b,
                    Cmp::Lt => order(ty, a, b) == Less,
                    Cmp::Le => order(ty, a, b) != Greater,
                    Cmp::Gt => order(ty, a, b) == Greater,
                    Cmp::Ge => order(ty, a, b) != Less,
                }
            }
            Pred::Contains(negated, needle, haystack) => {
                symbol(haystack.eval(ctx)).contains(symbol(needle.eval(ctx))) != *negated
            }
            Pred::MatchLiteral(negated, pattern, haystack) => {
                pattern
                    .regex()
                    .is_some_and(|re| re.is_match(symbol(haystack.eval(ctx))))
                    != *negated
            }
            Pred::Match(negated, pattern, haystack) => {
                let pattern = format!("^(?:{})$", symbol(pattern.eval(ctx)));
                Regex::new(&pattern).is_ok_and(|re| re.is_match(symbol(haystack.eval(ctx))))
                    != *negated
            }
        }
    }
}

// =============================================================================
// The plan
// =============================================================================

/// One step of the plan, compiled: what it reads, what it computes, and
/// the collection it binds.
#[derive(Debug, Serialize, Deserialize)]
enum Step {
    /// A map and filter over one collection.
    Map {
        input: u64,
        output: u64,
        shape: Shape,
        key: Vec<Expr>,
        value: Vec<Expr>,
        preds: Vec<Pred>,
    },
    /// A join of two collections on their keys.
    Join {
        left: u64,
        right: u64,
        output: u64,
        key: Vec<Expr>,
        value: Vec<Expr>,
        preds: Vec<Pred>,
    },
    /// `right`'s pairs whose key `left` lacks, mapped.
    Antijoin {
        left: u64,
        right: u64,
        output: u64,
        key: Vec<Expr>,
        value: Vec<Expr>,
    },
}

impl std::fmt::Debug for Shape {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Shape::Row => "Row",
            Shape::Kv => "Kv",
            Shape::Join => "Join",
        })
    }
}

/// A relation a stratum binds: the union of its earlier binding (when it
/// has one) and its head collections, deduplicated, then aggregated.
#[derive(Debug, Serialize, Deserialize)]
struct Head {
    relation: u64,
    earlier: bool,
    parts: Vec<u64>,
    aggregate: Option<Aggregate>,
}

/// The aggregates the generic engine computes.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
enum Agg {
    Count,
    Sum,
    Min,
    Max,
}

#[derive(Debug, Serialize, Deserialize)]
struct Aggregate {
    op: Agg,
    position: usize,
    arity: usize,
}

impl Aggregate {
    /// A count or sum with no group answers zero over no rows, as the
    /// compiled engine's does.
    fn seeded(&self) -> bool {
        self.arity == 1 && matches!(self.op, Agg::Count | Agg::Sum)
    }
}

impl Stratum {
    fn seeds(&self) -> bool {
        self.heads
            .iter()
            .any(|h| h.aggregate.as_ref().is_some_and(Aggregate::seeded))
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct Stratum {
    prelude: Vec<Step>,
    /// A recursive stratum's loop: what enters it, its feedback relations,
    /// its body, and what leaves it.
    recursion: Option<Recursion>,
    heads: Vec<Head>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Recursion {
    enter: Vec<u64>,
    feedback: Vec<u64>,
    body: Vec<Step>,
    leave: Vec<u64>,
}

impl Recursion {
    /// The collections the loop's body arranges to join on.
    fn joined(&self) -> HashSet<u64> {
        self.body
            .iter()
            .flat_map(|step| match step {
                Step::Join { left, right, .. } => vec![*left, *right],
                Step::Map { .. } | Step::Antijoin { .. } => vec![],
            })
            .collect()
    }
}

/// An input relation: its collection, and its inline facts.
#[derive(Serialize, Deserialize)]
struct InputPlan {
    relation: u64,
    facts: Vec<Vec<Lit>>,
}

#[derive(Serialize, Deserialize)]
struct Output {
    relation: u64,
}

/// The program, planned and compiled: what every worker builds its
/// dataflow from.
#[derive(Serialize, Deserialize)]
struct Plan {
    inputs: Vec<InputPlan>,
    strata: Vec<Stratum>,
    outputs: Vec<Output>,
}

fn column(data_type: &DataType) -> Result<Column, String> {
    match data_type {
        DataType::String => Ok(Column::Symbol),
        DataType::Int32 => Ok(Column::Number),
        other => Err(format!("argus exchanges no `{other}` columns")),
    }
}

impl Plan {
    fn new(program: &Program, planner: &ProgramPlanner) -> Result<Self, String> {
        let mut types: HashMap<u64, (Vec<Ty>, Vec<Ty>)> = HashMap::new();
        let declared = |fp: u64| -> Result<Vec<Ty>, String> {
            let relation = program
                .relations()
                .iter()
                .find(|r| r.fingerprint() == fp)
                .ok_or_else(|| format!("planner error: no relation 0x{fp:016x}"))?;
            relation.data_type().iter().map(Ty::of).collect()
        };

        let mut inputs = Vec::new();
        for relation in program.edbs() {
            let row = relation
                .data_type()
                .iter()
                .map(Ty::of)
                .collect::<Result<Vec<_>, _>>()?;
            types.insert(relation.fingerprint(), (Vec::new(), row));
            let facts = match program.facts().get(relation.name()) {
                Some(facts) => facts
                    .iter()
                    .map(|fact| {
                        fact.columns
                            .iter()
                            .map(Lit::of)
                            .collect::<Result<Vec<_>, _>>()
                    })
                    .collect::<Result<Vec<_>, _>>()?,
                None => Vec::new(),
            };
            if relation.has_input() {
                relation
                    .data_type()
                    .iter()
                    .map(column)
                    .collect::<Result<Vec<_>, _>>()?;
            }
            inputs.push(InputPlan {
                relation: relation.fingerprint(),
                facts,
            });
        }

        let mut strata = Vec::new();
        for stratum in planner.strata() {
            let prelude = stratum
                .non_recursive_transformations()
                .iter()
                .map(|tx| step(tx, &mut types))
                .collect::<Result<Vec<_>, _>>()?;
            let recursion =
                if stratum.is_recursive() && !stratum.recursion_leave_collections().is_empty() {
                    // A feedback relation is read before its head binds it:
                    // its type is its declaration's.
                    for fp in stratum.recursion_feedback_collections() {
                        types.insert(*fp, (Vec::new(), declared(*fp)?));
                    }
                    let body = stratum
                        .recursive_transformations()
                        .iter()
                        .map(|tx| step(tx, &mut types))
                        .collect::<Result<Vec<_>, _>>()?;
                    Some(Recursion {
                        enter: stratum.recursion_enter_collections().to_vec(),
                        feedback: stratum.recursion_feedback_collections().to_vec(),
                        body,
                        leave: stratum.recursion_leave_collections().to_vec(),
                    })
                } else {
                    None
                };
            let mut heads = Vec::new();
            let mut idbs: Vec<(&u64, &Vec<u64>)> = stratum.idb_to_heads_map().iter().collect();
            idbs.sort_by_key(|(fp, _)| **fp);
            for (idb, parts) in idbs {
                let row = declared(*idb)?;
                let aggregate = match stratum.idb_to_aggregation_map().get(idb) {
                    Some((op, position, arity)) => {
                        let ty = row.get(*position).cloned().ok_or_else(|| {
                            "planner error: an aggregate past the relation's end".to_string()
                        })?;
                        let op = match (op, &ty) {
                            (AggregationOperator::Count, _) => Agg::Count,
                            (AggregationOperator::Sum, Ty::Num) => Agg::Sum,
                            (AggregationOperator::Min, Ty::Num) => Agg::Min,
                            (AggregationOperator::Max, Ty::Num) => Agg::Max,
                            (op, ty) => {
                                return Err(format!(
                                    "the generic engine has no `{op}` over {ty:?} columns"
                                ));
                            }
                        };
                        Some(Aggregate {
                            op,
                            position: *position,
                            arity: *arity,
                        })
                    }
                    None => None,
                };
                types.insert(*idb, (Vec::new(), row));
                heads.push(Head {
                    relation: *idb,
                    earlier: false,
                    parts: parts.clone(),
                    aggregate,
                });
            }
            strata.push(Stratum {
                prelude,
                recursion,
                heads,
            });
        }

        let outputs = program
            .output_idbs()
            .into_iter()
            .map(|relation| {
                relation
                    .data_type()
                    .iter()
                    .map(column)
                    .collect::<Result<Vec<_>, String>>()?;
                Ok(Output {
                    relation: relation.fingerprint(),
                })
            })
            .collect::<Result<Vec<_>, String>>()?;

        let mut plan = Plan {
            inputs,
            strata,
            outputs,
        };
        plan.mark_earlier(program);
        Ok(plan)
    }

    /// A head folds in its relation's earlier binding when an input or an
    /// earlier stratum bound it, or, in a loop, when it entered the loop.
    fn mark_earlier(&mut self, program: &Program) {
        let mut bound: HashSet<u64> = program.edb_fingerprints().into_iter().collect();
        for stratum in &mut self.strata {
            let entered: HashSet<u64> = stratum
                .recursion
                .as_ref()
                .map(|r| r.enter.iter().copied().collect())
                .unwrap_or_default();
            for head in &mut stratum.heads {
                head.earlier = if stratum.recursion.is_some() {
                    entered.contains(&head.relation)
                } else {
                    bound.contains(&head.relation)
                };
            }
            bound.extend(stratum.heads.iter().map(|h| h.relation));
        }
    }
}

/// Compiles one transformation, recording its output's types.
fn step(tx: &Transformation, types: &mut HashMap<u64, (Vec<Ty>, Vec<Ty>)>) -> Result<Step, String> {
    let of = |fp: u64, types: &HashMap<u64, (Vec<Ty>, Vec<Ty>)>| {
        types
            .get(&fp)
            .cloned()
            .ok_or_else(|| format!("planner error: collection 0x{fp:016x} read before it is bound"))
    };
    let output = tx.output();
    let keyed = matches!(
        tx,
        Transformation::RowToKv { .. }
            | Transformation::KvToKv { .. }
            | Transformation::JnToKv { .. }
            | Transformation::NJnToKv { .. }
    );
    let flow = tx.flow();
    let compile_all = |args: &[ArithmeticArgument], t: &Types<'_>| {
        args.iter()
            .map(|a| compile(a, t))
            .collect::<Result<Vec<_>, _>>()
    };
    let split =
        |compiled: Vec<(Expr, Ty)>| -> (Vec<Expr>, Vec<Ty>) { compiled.into_iter().unzip() };

    let (step, key_types, value_types) = match tx {
        Transformation::RowToRow { input, .. }
        | Transformation::RowToKv { input, .. }
        | Transformation::KvToRow { input, .. }
        | Transformation::KvToKv { input, .. } => {
            let shape = match tx {
                Transformation::RowToRow { .. } | Transformation::RowToKv { .. } => Shape::Row,
                _ => Shape::Kv,
            };
            let (key_in, value_in) = of(input.fingerprint(), types)?;
            let t = Types {
                shape,
                key: &key_in,
                value: &value_in,
                right_value: &[],
            };
            let (key, key_types) = if keyed {
                split(compile_all(flow.key(), &t)?)
            } else {
                (Vec::new(), Vec::new())
            };
            let (value, value_types) = if keyed && output.is_k_only() {
                (Vec::new(), Vec::new())
            } else {
                split(compile_all(flow.value(), &t)?)
            };
            let preds = predicates(flow, &t)?;
            (
                Step::Map {
                    input: input.fingerprint(),
                    output: output.fingerprint(),
                    shape,
                    key,
                    value,
                    preds,
                },
                key_types,
                value_types,
            )
        }
        Transformation::JnToRow {
            input: (left, right),
            ..
        }
        | Transformation::JnToKv {
            input: (left, right),
            ..
        } => {
            let (left_key, left_value) = of(left.fingerprint(), types)?;
            let (_, right_value) = of(right.fingerprint(), types)?;
            let t = Types {
                shape: Shape::Join,
                key: &left_key,
                value: &left_value,
                right_value: &right_value,
            };
            let (key, key_types) = if keyed {
                split(compile_all(flow.key(), &t)?)
            } else {
                (Vec::new(), Vec::new())
            };
            let (value, value_types) = if keyed && output.is_k_only() {
                (Vec::new(), Vec::new())
            } else {
                split(compile_all(flow.value(), &t)?)
            };
            let preds = predicates(flow, &t)?;
            (
                Step::Join {
                    left: left.fingerprint(),
                    right: right.fingerprint(),
                    output: output.fingerprint(),
                    key,
                    value,
                    preds,
                },
                key_types,
                value_types,
            )
        }
        Transformation::NJnToRow {
            input: (left, right),
            ..
        }
        | Transformation::NJnToKv {
            input: (left, right),
            ..
        } => {
            let (right_key, right_value) = of(right.fingerprint(), types)?;
            let t = Types {
                shape: Shape::Kv,
                key: &right_key,
                value: &right_value,
                right_value: &[],
            };
            let (key, key_types) = if keyed {
                split(compile_all(flow.key(), &t)?)
            } else {
                (Vec::new(), Vec::new())
            };
            let (value, value_types) = if keyed && output.is_k_only() {
                (Vec::new(), Vec::new())
            } else {
                split(compile_all(flow.value(), &t)?)
            };
            (
                Step::Antijoin {
                    left: left.fingerprint(),
                    right: right.fingerprint(),
                    output: output.fingerprint(),
                    key,
                    value,
                },
                key_types,
                value_types,
            )
        }
    };
    types.insert(output.fingerprint(), (key_types, value_types));
    Ok(step)
}

/// A step's comparisons and equality constraints, as filters.
fn predicates(flow: &TransformationFlow, t: &Types<'_>) -> Result<Vec<Pred>, String> {
    let mut preds = Vec::new();
    for compare in flow.compares() {
        preds.push(compile_compare(
            compare.operator(),
            compare.left(),
            compare.right(),
            t,
        )?);
    }
    if let TransformationFlow::KVToKV { constraints, .. } = flow {
        for (arg, c) in constraints.constant_eq_constraints().iter() {
            let (slot, ty) = t.slot(arg)?;
            preds.push(Pred::Compare(
                Cmp::Eq,
                ty,
                Expr::Col(slot),
                Expr::Const(Const::new(Lit::of(c)?)),
            ));
        }
        for (a, b) in constraints.variable_eq_constraints().iter() {
            let (slot_a, ty) = t.slot(a)?;
            let (slot_b, _) = t.slot(b)?;
            preds.push(Pred::Compare(
                Cmp::Eq,
                ty,
                Expr::Col(slot_a),
                Expr::Col(slot_b),
            ));
        }
    }
    Ok(preds)
}

// =============================================================================
// The dataflow
// =============================================================================

type Coll<'scope, T> = VecCollection<'scope, T, Kv, Diff>;
type Trace<T> = TraceAgent<ValSpine<Row, Row, T, Diff>>;

/// A scope's time: the outer epoch, or a loop's inside it.
trait Time: Timestamp + Lattice + Ord + Refines<Epoch> {}
impl<T: Timestamp + Lattice + Ord + Refines<Epoch>> Time for T {}

/// An arrangement a join reads: one built in this scope, or one built
/// outside a loop and entered into it, which the loop reads without
/// arranging its rows again.
enum Arr<'scope, T: Time> {
    Own(Arranged<'scope, Trace<T>>),
    Entered(Arranged<'scope, TraceEnter<Trace<Epoch>, T>>),
}

impl<T: Time> Clone for Arr<'_, T> {
    fn clone(&self) -> Self {
        match self {
            Arr::Own(arranged) => Arr::Own(arranged.clone()),
            Arr::Entered(arranged) => Arr::Entered(arranged.clone()),
        }
    }
}

/// The collections a scope has bound, by fingerprint, and the arrangements
/// built of them, or entered, so far.
struct Env<'scope, T: Time> {
    collections: HashMap<u64, Coll<'scope, T>>,
    arranged: HashMap<u64, Arr<'scope, T>>,
}

impl<'scope, T: Time> Env<'scope, T> {
    fn new() -> Self {
        Env {
            collections: HashMap::new(),
            arranged: HashMap::new(),
        }
    }

    fn get(&self, fp: u64) -> Coll<'scope, T> {
        self.collections
            .get(&fp)
            .cloned()
            .unwrap_or_else(|| panic!("planner error: collection 0x{fp:016x} is unbound"))
    }

    fn arrangement(&mut self, fp: u64) -> Arr<'scope, T> {
        if let Some(arranged) = self.arranged.get(&fp) {
            return arranged.clone();
        }
        let arranged = Arr::Own(self.get(fp).arrange_by_key());
        self.arranged.insert(fp, arranged.clone());
        arranged
    }

    fn bind(&mut self, fp: u64, collection: Coll<'scope, T>) {
        self.arranged.remove(&fp);
        self.collections.insert(fp, collection);
    }
}

impl<'scope> Env<'scope, Epoch> {
    /// `fp`'s arrangement in this outer scope, as a loop enters it.
    fn outer_arrangement(&mut self, fp: u64) -> Arranged<'scope, Trace<Epoch>> {
        match self.arrangement(fp) {
            Arr::Own(arranged) => arranged,
            Arr::Entered(_) => unreachable!("an outer scope enters nothing"),
        }
    }
}

/// `left` joined with `right` on their keys, each match mapped by `logic`.
fn join<'scope, T: Time>(
    left: Arr<'scope, T>,
    right: Arr<'scope, T>,
    logic: impl Fn(&Row, &Row, &Row) -> Option<Kv> + Clone + 'static,
) -> Coll<'scope, T> {
    match (left, right) {
        (Arr::Own(l), Arr::Own(r)) => {
            l.join_core(r, move |k: &Row, lv: &Row, rv: &Row| logic(k, lv, rv))
        }
        (Arr::Own(l), Arr::Entered(r)) => {
            l.join_core(r, move |k: &Row, lv: &Row, rv: &Row| logic(k, lv, rv))
        }
        (Arr::Entered(l), Arr::Own(r)) => {
            l.join_core(r, move |k: &Row, lv: &Row, rv: &Row| logic(k, lv, rv))
        }
        (Arr::Entered(l), Arr::Entered(r)) => {
            l.join_core(r, move |k: &Row, lv: &Row, rv: &Row| logic(k, lv, rv))
        }
    }
}

fn project(exprs: &[Expr], ctx: &Ctx<'_>) -> Row {
    exprs.iter().map(|e| e.eval(ctx)).collect()
}

/// Builds `step` in `env`.
fn build_step<'scope, T: Time>(env: &mut Env<'scope, T>, step: &'static Step) {
    match step {
        Step::Map {
            input,
            output,
            shape,
            key,
            value,
            preds,
        } => {
            let shape = *shape;
            let mapped = env.get(*input).flat_map(move |(k, v)| {
                let ctx = match shape {
                    Shape::Row => Ctx {
                        key: &[],
                        value: &v,
                        left: &[],
                        right: &[],
                    },
                    _ => Ctx {
                        key: &k,
                        value: &v,
                        left: &[],
                        right: &[],
                    },
                };
                preds
                    .iter()
                    .all(|p| p.holds(&ctx))
                    .then(|| (project(key, &ctx), project(value, &ctx)))
            });
            env.bind(*output, mapped);
        }
        Step::Join {
            left,
            right,
            output,
            key,
            value,
            preds,
        } => {
            let (l, r) = (env.arrangement(*left), env.arrangement(*right));
            let joined = join(l, r, move |k: &Row, lv: &Row, rv: &Row| {
                let ctx = Ctx {
                    key: k,
                    value: lv,
                    left: lv,
                    right: rv,
                };
                preds
                    .iter()
                    .all(|p| p.holds(&ctx))
                    .then(|| (project(key, &ctx), project(value, &ctx)))
            });
            env.bind(*output, joined);
        }
        Step::Antijoin {
            left,
            right,
            output,
            key,
            value,
        } => {
            // The keys a left row holds, each once: an antijoin subtracts
            // the semijoin, which a key held twice would subtract twice.
            let keys = env.get(*left).map(|(k, _)| k).distinct_core::<Diff>();
            let kept = env.get(*right).antijoin(keys).map(move |(k, v)| {
                let ctx = Ctx {
                    key: &k,
                    value: &v,
                    left: &[],
                    right: &[],
                };
                (project(key, &ctx), project(value, &ctx))
            });
            env.bind(*output, kept);
        }
    }
}

/// Binds `head`'s relation in `env`: its parts and its `earlier` binding,
/// unioned and deduplicated, then aggregated. `seed` holds one empty row,
/// for a count or sum with no group to answer zero over no rows.
fn build_head<'scope, T>(
    env: &mut Env<'scope, T>,
    head: &'static Head,
    earlier: Option<Coll<'scope, T>>,
    seed: Option<Coll<'scope, T>>,
) where
    T: Time,
{
    let mut parts: Vec<Coll<'scope, T>> = earlier.into_iter().collect();
    parts.extend(head.parts.iter().map(|fp| env.get(*fp)));
    let first = parts.remove(0);
    let union = if parts.is_empty() {
        first
    } else {
        first.concatenate(parts)
    };
    let deduped = union.distinct_core::<Diff>();
    let bound = match &head.aggregate {
        None => deduped,
        Some(aggregate) => build_aggregate(deduped, aggregate, seed),
    };
    env.bind(head.relation, bound);
}

fn build_aggregate<'scope, T>(
    rows: Coll<'scope, T>,
    aggregate: &'static Aggregate,
    seed: Option<Coll<'scope, T>>,
) -> Coll<'scope, T>
where
    T: Time,
{
    let position = aggregate.position;
    // A group: the row without the aggregated column; its member, the
    // column, or none for the seed.
    let members = rows.map(move |(_, row)| {
        let mut group = row.clone();
        let value = group.remove(position);
        (group, Some(value))
    });
    let members = match seed {
        Some(seed) if aggregate.seeded() => members.concat(seed.map(|(_, row)| (row, None))),
        _ => members,
    };
    let op = aggregate.op;
    let reduced = members.reduce(
        move |_group: &Row, input: &[(&Option<u32>, Diff)], output: &mut Vec<(u32, Diff)>| {
            let values = input
                .iter()
                .filter_map(|(value, diff)| value.map(|v| (v, *diff)));
            let answer = match op {
                Agg::Count => Some(values.map(|(_, d)| d).sum::<i32>()),
                Agg::Sum => Some(values.fold(0_i32, |sum, (v, d)| {
                    sum.wrapping_add(number(v).wrapping_mul(d))
                })),
                Agg::Min => values.map(|(v, _)| number(v)).min(),
                Agg::Max => values.map(|(v, _)| number(v)).max(),
            };
            if let Some(answer) = answer {
                output.push((slot_of_number(answer), 1));
            }
        },
    );
    reduced.map(move |(mut group, answer)| {
        group.insert(position, answer);
        (Row::new(), group)
    })
}

/// Builds the plan's dataflow in `scope`: an input session per input
/// relation, and each output's changes pushed into its sink.
fn build<'scope>(
    scope: Scope<'scope, Epoch>,
    plan: &'static Plan,
    sinks: &[Sink],
    probe: &mut ProbeHandle<Epoch>,
) -> Vec<InputSession<Epoch, Kv, Diff>> {
    let mut env: Env<'scope, Epoch> = Env::new();
    let mut sessions = Vec::with_capacity(plan.inputs.len());
    for input in &plan.inputs {
        let (session, collection) = scope.new_collection::<Kv, Diff>();
        env.bind(input.relation, collection);
        sessions.push(session);
    }
    for stratum in &plan.strata {
        for step in &stratum.prelude {
            build_step(&mut env, step);
        }
        // One empty row from the start, for a seeded aggregate.
        let seed = stratum.seeds().then(|| {
            vec![((Row::new(), Row::new()), 0, 1)]
                .to_stream(scope)
                .as_collection()
        });
        match &stratum.recursion {
            None => {
                for head in &stratum.heads {
                    let earlier = head.earlier.then(|| env.get(head.relation));
                    build_head(&mut env, head, earlier, seed.clone());
                }
            }
            Some(recursion) => {
                let entering: Vec<(u64, Coll<'scope, Epoch>)> = recursion
                    .enter
                    .iter()
                    .map(|fp| (*fp, env.get(*fp)))
                    .collect();
                // What the loop joins on of what enters it is arranged out
                // here, once, and entered: arranged inside, it would be
                // arranged again, and held again, by the loop.
                let joined = recursion.joined();
                let entering_arranged: Vec<(u64, Arranged<'scope, Trace<Epoch>>)> = recursion
                    .enter
                    .iter()
                    .filter(|fp| joined.contains(fp))
                    .map(|fp| (*fp, env.outer_arrangement(*fp)))
                    .collect();
                let left = scope.scoped::<LoopTime, _, _>("Iterative", |inner| {
                    let mut env_in: Env<'_, LoopTime> = Env::new();
                    // A head unions what entered, not its feedback variable,
                    // which shares the relation's fingerprint inside.
                    let mut entered = HashMap::new();
                    for (fp, collection) in &entering {
                        let collection = collection.clone().enter(inner);
                        entered.insert(*fp, collection.clone());
                        env_in.bind(*fp, collection);
                    }
                    for (fp, arranged) in &entering_arranged {
                        env_in
                            .arranged
                            .insert(*fp, Arr::Entered(arranged.clone().enter(inner)));
                    }
                    let mut variables = Vec::new();
                    for fp in &recursion.feedback {
                        let (variable, collection) = Variable::<_, Vec<(Kv, LoopTime, Diff)>>::new(
                            inner,
                            Product::new(0, 1),
                        );
                        env_in.bind(*fp, collection);
                        variables.push((*fp, variable));
                    }
                    for step in &recursion.body {
                        build_step(&mut env_in, step);
                    }
                    let seed_in = seed.clone().map(|seed| seed.enter(inner));
                    for head in &stratum.heads {
                        let earlier = if head.earlier {
                            entered.get(&head.relation).cloned()
                        } else {
                            None
                        };
                        build_head(&mut env_in, head, earlier, seed_in.clone());
                    }
                    for (fp, variable) in variables {
                        variable.set(env_in.get(fp));
                    }
                    recursion
                        .leave
                        .iter()
                        .map(|fp| (*fp, env_in.get(*fp).leave(scope)))
                        .collect::<Vec<_>>()
                });
                for (fp, collection) in left {
                    env.bind(fp, collection);
                }
            }
        }
    }

    for (output, sink) in plan.outputs.iter().zip(sinks) {
        let Some(collection) = env.collections.get(&output.relation).cloned() else {
            continue;
        };
        let sink = Arc::clone(sink);
        collection
            .inspect(move |((_, row), _time, diff)| {
                sink.lock()
                    .expect("an output sink")
                    .push((row.clone(), *diff))
            })
            .probe_with(probe);
    }
    sessions
}

// =============================================================================
// The engine
// =============================================================================

enum Command {
    /// Load these batches at the current epoch, then advance to `epoch`.
    Commit {
        epoch: Epoch,
        batches: Arc<Vec<(usize, Vec<Row>, Diff)>>,
    },
}

/// The generic engine as the host drives it: the plan's dataflow on its
/// own workers, fed a commit at a time.
pub struct Generic {
    digest: String,
    inputs: &'static [Relation],
    outputs: &'static [Relation],
    /// Each host-visible input's index among the plan's inputs.
    input_index: Vec<usize>,
    plan: &'static Plan,
    staged: Vec<(usize, Vec<Row>, Diff)>,
    epoch: Epoch,
    commands: Vec<mpsc::Sender<Command>>,
    done: mpsc::Receiver<()>,
    sinks: Vec<Sink>,
    workers: Option<JoinHandle<()>>,
}

fn leak_relations(relations: Vec<(String, String, Vec<Column>)>) -> &'static [Relation] {
    let relations: Vec<Relation> = relations
        .into_iter()
        .map(|(name, file, columns)| Relation {
            name: Box::leak(name.into_boxed_str()),
            file: Box::leak(file.into_boxed_str()),
            columns: Box::leak(columns.into_boxed_slice()),
        })
        .collect();
    Box::leak(relations.into_boxed_slice())
}

/// Whether the generic engine runs `program`, or why it does not: a
/// column, constant or aggregate it has no slot for, or a user-defined
/// function.
pub fn check(program: &Program) -> Result<(), String> {
    let planner =
        ProgramPlanner::from_program(program, &mut None).map_err(|error| error.to_string())?;
    Plan::new(program, &planner).map(|_| ())
}

/// A relation the host exchanges, as a prepared program keeps it.
#[derive(Serialize, Deserialize)]
struct IoSpec {
    name: String,
    file: String,
    /// Each column's type, `symbol` or `number`.
    columns: Vec<String>,
}

impl IoSpec {
    fn of(io: &crate::Io) -> Self {
        IoSpec {
            name: io.name.clone(),
            file: io.file.clone(),
            columns: io
                .columns
                .iter()
                .map(|c| c.host().name().to_string())
                .collect(),
        }
    }

    fn relation(&self) -> Result<(String, String, Vec<Column>), String> {
        let columns = self
            .columns
            .iter()
            .map(|c| match c.as_str() {
                "symbol" => Ok(Column::Symbol),
                "number" => Ok(Column::Number),
                other => Err(format!("a cached plan names a `{other}` column")),
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok((self.name.clone(), self.file.clone(), columns))
    }
}

/// A program as `serve` runs it: its relations as the host addresses them,
/// and its plan. It is what `--plan-cache` keeps, so an engine started
/// again for the same program digest neither parses nor plans it.
#[derive(Serialize, Deserialize)]
struct Prepared {
    inputs: Vec<IoSpec>,
    outputs: Vec<IoSpec>,
    /// Each host input's index among the plan's inputs.
    input_index: Vec<usize>,
    /// Each host output's index among the plan's outputs.
    output_order: Vec<usize>,
    plan: Plan,
}

impl Prepared {
    /// Parses and plans the program at `program`.
    fn plan(program: &Path) -> Result<Self, String> {
        let started = std::time::Instant::now();
        let path = program
            .to_str()
            .ok_or_else(|| format!("non-UTF-8 program path: {}", program.display()))?;
        let mut sources = SourceMap::new();
        let mut config = Config {
            program: path.to_string(),
            str_intern: true,
            ..Config::default()
        };
        let parsed = flowlog_parser::parse(path, &[] as &[&Path], &mut sources, &mut config)
            .map_err(|error| crate::render(&error.into(), &sources))?;
        let (inputs, outputs) = crate::interface(&parsed).map_err(|failure| match failure {
            crate::Failure::Program(text) => text,
            crate::Failure::Usage => unreachable!("interface reports programs only"),
        })?;
        let planner = ProgramPlanner::from_program(&parsed, &mut None)
            .map_err(|error| crate::render(&error, &sources))?;
        let plan = Plan::new(&parsed, &planner)?;

        // The host addresses inputs and outputs as the interface lists them.
        let input_index = inputs
            .iter()
            .map(|io| {
                let fp = parsed
                    .edbs()
                    .iter()
                    .find(|r| r.raw_name() == io.name)
                    .map(|r| r.fingerprint());
                plan.inputs
                    .iter()
                    .position(|input| Some(input.relation) == fp)
                    .ok_or_else(|| format!("planner error: input `{}` has no collection", io.name))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let output_order = outputs
            .iter()
            .map(|io| {
                let fp = parsed
                    .output_idbs()
                    .iter()
                    .find(|r| r.raw_name() == io.name)
                    .map(|r| r.fingerprint());
                plan.outputs
                    .iter()
                    .position(|output| Some(output.relation) == fp)
                    .ok_or_else(|| format!("planner error: output `{}` has no collection", io.name))
            })
            .collect::<Result<Vec<_>, _>>()?;
        // The engine's log says what its start cost, for a slow one.
        eprintln!(
            "generic engine: {} planned in {:?}",
            program.display(),
            started.elapsed()
        );
        Ok(Prepared {
            inputs: inputs.iter().map(IoSpec::of).collect(),
            outputs: outputs.iter().map(IoSpec::of).collect(),
            input_index,
            output_order,
            plan,
        })
    }

    /// The prepared program kept at `cache`, or `None` when there is none
    /// or it does not read back whole.
    fn load(cache: &Path) -> Option<Self> {
        let bytes = std::fs::read(cache).ok()?;
        match serde_json::from_slice(&bytes) {
            Ok(prepared) => Some(prepared),
            Err(error) => {
                eprintln!(
                    "generic engine: ignoring the plan at {}: {error}",
                    cache.display()
                );
                None
            }
        }
    }

    /// Keeps this at `cache`, written beside it and renamed into place, so
    /// a reader sees a whole plan or none. A plan that cannot be kept is
    /// planned again next time.
    fn store(&self, cache: &Path) {
        let staged = cache.with_extension(format!("{}.tmp", std::process::id()));
        let written = cache
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| serde_json::to_vec(self).map_err(std::io::Error::other))
            .and_then(|bytes| std::fs::write(&staged, bytes))
            .and_then(|()| std::fs::rename(&staged, cache));
        if let Err(error) = written {
            let _ = std::fs::remove_file(&staged);
            eprintln!(
                "generic engine: cannot keep the plan at {}: {error}",
                cache.display()
            );
        }
    }
}

impl Generic {
    /// Starts the program at `program`'s dataflow on `workers` threads;
    /// `digest` is what `hello` reports. With a `cache`, the program is
    /// planned only when the cache holds no plan for it, and the plan is
    /// kept there: the caller names one cache per program digest.
    pub fn new(
        program: &Path,
        digest: String,
        workers: usize,
        cache: Option<&Path>,
    ) -> Result<Self, String> {
        let prepared = match cache.and_then(Prepared::load) {
            Some(prepared) => prepared,
            None => {
                let prepared = Prepared::plan(program)?;
                if let Some(cache) = cache {
                    prepared.store(cache);
                }
                prepared
            }
        };
        let Prepared {
            inputs,
            outputs,
            input_index,
            output_order,
            plan,
        } = prepared;
        let plan: &'static Plan = Box::leak(Box::new(plan));
        let sinks: Vec<Sink> = plan
            .outputs
            .iter()
            .map(|_| Arc::new(Mutex::new(Vec::new())))
            .collect();
        // The host's outputs are the interface's; the plan's sinks follow
        // the plan's order.
        let sinks_in_order: Vec<_> = output_order
            .iter()
            .map(|&i| Arc::clone(&sinks[i]))
            .collect();

        let workers = workers.max(1);
        let (senders, receivers): (Vec<_>, Vec<_>) =
            (0..workers).map(|_| mpsc::channel::<Command>()).unzip();
        let receivers = Arc::new(Mutex::new(
            receivers.into_iter().map(Some).collect::<Vec<_>>(),
        ));
        let (done_tx, done) = mpsc::channel();
        let worker_sinks = sinks.clone();
        let handle = std::thread::spawn(move || {
            let done_tx = Mutex::new(done_tx);
            let result = timely::execute(timely::Config::process(workers), move |worker| {
                let index = worker.index();
                let commands = receivers.lock().expect("the command queues")[index]
                    .take()
                    .expect("each worker takes its own queue");
                let done_tx = done_tx.lock().expect("the done channel").clone();
                let mut probe = ProbeHandle::new();
                let building = std::time::Instant::now();
                let mut sessions = worker
                    .dataflow::<Epoch, _, _>(|scope| build(scope, plan, &worker_sinks, &mut probe));
                if index == 0 {
                    eprintln!("generic engine: dataflow built in {:?}", building.elapsed());
                }
                // A relation's inline facts are part of the program: the
                // first commit loads them with the inputs.
                if index == 0 {
                    for (session, input) in sessions.iter_mut().zip(&plan.inputs) {
                        for fact in &input.facts {
                            session.update((Row::new(), fact.iter().map(Lit::slot).collect()), 1);
                        }
                    }
                }
                while let Ok(Command::Commit { epoch, batches }) = commands.recv() {
                    if index == 0 {
                        for (input, rows, diff) in batches.iter() {
                            for row in rows {
                                sessions[*input].update((Row::new(), row.clone()), *diff);
                            }
                        }
                    }
                    for session in &mut sessions {
                        session.advance_to(epoch);
                        session.flush();
                    }
                    worker.step_while(|| probe.less_than(&epoch));
                    if done_tx.send(()).is_err() {
                        break;
                    }
                }
            });
            if let Err(error) = result {
                eprintln!("the generic engine's workers failed: {error}");
                std::process::exit(1);
            }
        });

        let inputs = inputs
            .iter()
            .map(IoSpec::relation)
            .collect::<Result<Vec<_>, _>>()?;
        let outputs = outputs
            .iter()
            .map(IoSpec::relation)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Generic {
            digest,
            inputs: leak_relations(inputs),
            outputs: leak_relations(outputs),
            input_index,
            plan,
            staged: Vec::new(),
            epoch: 0,
            commands: senders,
            done,
            sinks: sinks_in_order,
            workers: Some(handle),
        })
    }
}

impl Dataflow for Generic {
    fn digest(&self) -> &str {
        &self.digest
    }

    fn inputs(&self) -> &'static [Relation] {
        self.inputs
    }

    fn outputs(&self) -> &'static [Relation] {
        self.outputs
    }

    fn begin(&mut self) {
        self.staged.clear();
    }

    fn abort(&mut self) {
        self.staged.clear();
    }

    fn stage(&mut self, index: usize, lines: &[&[u8]], insert: bool) -> Result<(), String> {
        let relation = self
            .inputs
            .get(index)
            .ok_or_else(|| format!("no input relation at index {index}"))?;
        let mut rows = Vec::with_capacity(lines.len());
        for line in lines {
            let mut fields = Fields::new(relation, line)?;
            let mut row = Row::new();
            for column in relation.columns {
                row.push(match column {
                    Column::Symbol => slot_of_symbol(&fields.symbol()?),
                    Column::Number => slot_of_number(fields.number()?),
                });
            }
            fields.end()?;
            rows.push(row);
        }
        self.staged
            .push((self.input_index[index], rows, if insert { 1 } else { -1 }));
        Ok(())
    }

    fn commit(&mut self, changes: &mut Changes) {
        self.epoch += 1;
        let batches = Arc::new(std::mem::take(&mut self.staged));
        for sender in &self.commands {
            sender
                .send(Command::Commit {
                    epoch: self.epoch,
                    batches: Arc::clone(&batches),
                })
                .expect("the generic engine's workers are running");
        }
        for _ in &self.commands {
            self.done.recv().expect("every worker finishes the commit");
        }
        for (index, sink) in self.sinks.iter().enumerate() {
            let updates = std::mem::take(&mut *sink.lock().expect("an output sink"));
            // Consolidate, as the workers' shares arrive apart.
            let mut net: HashMap<Row, Diff> = HashMap::new();
            for (row, diff) in updates {
                *net.entry(row).or_insert(0) += diff;
            }
            let columns = self.outputs[index].columns;
            for (row, diff) in net {
                if diff == 0 {
                    continue;
                }
                let mut line = String::new();
                for (position, (column, slot)) in columns.iter().zip(&row).enumerate() {
                    if position > 0 {
                        line.push('\t');
                    }
                    match column {
                        Column::Symbol => line.push_str(symbol(*slot)),
                        Column::Number => line.push_str(itoa::Buffer::new().format(number(*slot))),
                    }
                }
                changes.record(index, line, diff.signum());
            }
        }
        let _ = self.plan;
    }
}

impl Drop for Generic {
    fn drop(&mut self) {
        // Closing the queues ends the workers' loops.
        self.commands.clear();
        if let Some(handle) = self.workers.take() {
            let _ = handle.join();
        }
    }
}
