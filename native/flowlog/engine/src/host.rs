//! What every engine shares, whatever its program: the relation tables'
//! shape, decoding a fact line into columns, and collecting a commit's
//! output deltas. `glue.rs`, generated per program, does the typed rest.

/// A column's type at the engine's boundary.
#[derive(Clone, Copy)]
pub enum Column {
    Symbol,
    Number,
}

impl Column {
    pub fn name(self) -> &'static str {
        match self {
            Column::Symbol => "symbol",
            Column::Number => "number",
        }
    }
}

/// An input or output relation: its name, the file argus names it by, and
/// its columns.
pub struct Relation {
    pub name: &'static str,
    pub file: &'static str,
    pub columns: &'static [Column],
}

/// The lines of a facts file: split on newlines, with only the newline
/// ending the last line dropped. An empty line in the middle is a row whose
/// one column is the empty string, as argus writes it (`Argus.Tsv`).
pub fn lines(bytes: &[u8]) -> Vec<&[u8]> {
    if bytes.is_empty() {
        return Vec::new();
    }
    let body = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    body.split(|&b| b == b'\n').collect()
}

/// The columns of one line, read in order. A symbol is the text between two
/// tabs as written: argus escapes tabs and newlines inside a value
/// (`Argus.Tsv`), and the escaped spelling travels through the rules and
/// back out unchanged.
pub struct Fields<'a> {
    relation: &'static Relation,
    line: &'a [u8],
    rest: std::slice::Split<'a, u8, fn(&u8) -> bool>,
    read: usize,
}

impl<'a> Fields<'a> {
    pub fn new(relation: &'static Relation, line: &'a [u8]) -> Result<Self, String> {
        fn tab(b: &u8) -> bool {
            *b == b'\t'
        }
        Ok(Fields {
            relation,
            line,
            rest: line.split(tab as fn(&u8) -> bool),
            read: 0,
        })
    }

    fn next(&mut self) -> Result<&'a [u8], String> {
        let field = self.rest.next().ok_or_else(|| self.arity_error())?;
        self.read += 1;
        Ok(field)
    }

    pub fn symbol(&mut self) -> Result<String, String> {
        let field = self.next()?;
        String::from_utf8(field.to_vec()).map_err(|_| self.error("is not UTF-8"))
    }

    pub fn number(&mut self) -> Result<i32, String> {
        let field = self.next()?;
        std::str::from_utf8(field)
            .ok()
            .and_then(|text| text.parse::<i32>().ok())
            .ok_or_else(|| self.error("is not a 32-bit number"))
    }

    /// Fails unless every column was read: a line with more columns than
    /// its relation is malformed, not truncated.
    pub fn end(&mut self) -> Result<(), String> {
        if self.rest.next().is_some() {
            return Err(self.arity_error());
        }
        Ok(())
    }

    fn arity_error(&self) -> String {
        let found = self.line.split(|&b| b == b'\t').count();
        format!(
            "a `{}` row has {found} columns, but the relation has {}: {}",
            self.relation.name,
            self.relation.columns.len(),
            String::from_utf8_lossy(self.line)
        )
    }

    fn error(&self, what: &str) -> String {
        format!(
            "column {} of a `{}` row {what}: {}",
            self.read,
            self.relation.name,
            String::from_utf8_lossy(self.line)
        )
    }
}

/// A commit's output deltas: each output's changed lines with their signed
/// weight, by output index.
pub struct Changes {
    outputs: Vec<Vec<(String, i32)>>,
}

impl Changes {
    pub fn new(outputs: usize) -> Self {
        Changes {
            outputs: vec![Vec::new(); outputs],
        }
    }

    pub fn record(&mut self, output: usize, line: String, diff: i32) {
        if diff != 0 {
            self.outputs[output].push((line, diff));
        }
    }

    pub fn into_outputs(self) -> Vec<Vec<(String, i32)>> {
        self.outputs
    }
}
