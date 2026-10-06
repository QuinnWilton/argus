# Used by "mix format"
[
  plugins: [Breeze.HTMLFormatter],
  import_deps: [:presubmit, :breeze],
  inputs: ["{mix,.formatter}.exs", "{config,examples,lib,test}/**/*.{ex,exs}"]
]
