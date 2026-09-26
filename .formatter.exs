# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: [
    tool: 2,
    resource: 2,
    read_resource: 2,
    read_resource: 3,
    call_tool: 3,
    call_tool: 4,
    assert_text: 2
  ],
  export: [
    locals_without_parens: [
      tool: 2,
      resource: 2,
      read_resource: 2,
      read_resource: 3,
      call_tool: 3,
      call_tool: 4,
      assert_text: 2
    ]
  ]
]
