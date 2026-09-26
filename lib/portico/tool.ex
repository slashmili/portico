defmodule Portico.Tool do
  @moduledoc ~S"""
  Defines a tool's metadata and application callback.

      defmodule MyApp.MCP.Tools.Add do
        use Portico.Tool,
          description: "Add two numbers",
          input_schema: %{
            type: "object",
            properties: %{a: %{type: "number"}, b: %{type: "number"}},
            required: ["a", "b"]
          }

        @impl true
        def call(%{"a" => a, "b" => b}, _request) do
          {:ok, result} = Portico.Result.text("#{a + b}")
          {:ok, result}
        end
      end

  The server supplies the exposed name with `tool "add", MyApp.MCP.Tools.Add`.
  A tool module can be reused under different names or by multiple servers.

  `:input_schema` and optional `:output_schema` must be plain maps.
  `:description` is an optional UTF-8 string. Schemas are checked at compilation against Draft 2020-12 and built
  into an internal validator. Atom map keys are normalized recursively to strings;
  duplicate normalized keys and non-JSON values are rejected. Values such as
  types and required property names must be JSON strings, not atoms. Catalogs
  expose the normalized schema. JSV is an internal implementation detail.
  `x-mcp-header` annotations in input schemas are rejected at compilation because
  custom MCP parameter header validation is not implemented. This includes nested
  input schemas; literal data in `const`, `enum`, `default`, and `examples` is unaffected.

  The initial dialect is `https://json-schema.org/draft/2020-12/schema`, also
  used when `$schema` is absent. Local references and bundled meta-schemas are
  available; no remote references are fetched. Unsupported dialects and unresolved
  references fail compilation. `format` and content keywords remain annotations,
  not assertions about string values or encoded content.

  Every tool must implement a public `call/2` callback. Use
  `Portico.Test.call_tool/4` to invoke it through the dispatcher, which checks
  the callback's return shape. Protocol calls also validate envelopes and core
  metadata and encode completed text and structured results. `Portico.Plug` serves HTTP requests;
  arguments are checked against the compiled schema before the callback runs.
  Invalid arguments return a completed tool error with field paths and reasons;
  the callback is skipped. Paths are JSON-quoted JSON Pointers (`""` means the
  root), and submitted values are not included. Missing fields and type errors
  have specific messages; other constraints identify the failed schema keyword. Valid arguments are passed unchanged, without coercion
  or insertion of schema defaults. JSON Schema integers include values such
  as `2.0`, so callbacks should account for both Elixir numeric representations.

  The request supplies assigns and client metadata; callbacks do not return it.
  `:ok` means a result was produced. The result's `is_error` flag distinguishes
  successful execution from an expected tool failure.

  Use `Portico.Result.structured/1` for JSON data, including a serialized text
  fallback. It returns the same constructor tuple; match `{:ok, result}` and
  return `{:ok, result}`. An optional `output_schema: %{...}` uses the same
  dialect, normalization, and local-reference rules as the input schema and is
  advertised as `outputSchema` in tool listings. It may describe any JSON type.

  When declared, every successful completed result must include matching
  structured content. Validation runs after `call/2`, `handle_input/3`, and
  `handle_stream/2`, without casting or inserting defaults. Missing or mismatched
  output returns `{:error, :invalid_output}` in tests and a sanitized internal
  error over HTTP (500, or the final event within an already-started 200 stream).
  Expected tool failures (`is_error: true`) bypass output-schema validation;
  malformed result content is still rejected. Input-required form responses are
  checked only when the tool eventually returns a completed result.

  Expected tool failures use the same callback shape:

      {:ok, result} = Portico.Result.error("Provide a valid date.")
      {:ok, result}

  This returns a completed result with `isError: true`. Unexpected callback
  exceptions remain generic protocol errors over HTTP and propagate in tests.

  Callbacks may return `{:error, reason}` when no result could be built.
  `Portico.Test.call_tool` preserves the reason; HTTP logs it server-side and
  sends a generic internal error. Use `Result.error/1` for client-visible tool
  failures instead. Reasons may be any Elixir term; avoid secrets in reasons
  because they appear in server logs.

  For form elicitation, return `{:ok, form, application_state}` from `call/2`
  and implement `handle_input/3`. Build the form with `Portico.Input.form/2`.
  If the client lacks form support, Portico returns protocol error `-32021`
  with the required capability. Test helpers return `{:error, :form_not_supported}`.
  HTTP uses status 400 unless an SSE response has already started; in that case
  the final event carries the error within the existing 200 response.
  Application state is a UTF-8 string; Portico wraps it and the form in a signed,
  expiring token. Configure a per-server key as described in `Portico.Elicitation`.

  The optional `elicitation_verifier: &MyApp.Elicitation.verify/2` must be an
  external function capture of arity two (including `&__MODULE__.verify/2`). It
  runs only on elicitation replies and returns `{:ok, verified_state}` or
  `{:error, reason}`. The default is `Portico.Elicitation.verify/2`.
  `handle_input/3` receives `{:accept, content}`, `:decline`, or `:cancel`, the
  verified application state, and the fresh request. The protected form schema
  is checked automatically; missing or invalid answers reissue the form without
  calling `handle_input/3`. A reply handler may finish, ask another form, or start
  a stream. Streaming callbacks may also return `{:ok, form, application_state}`;
  Portico sends the form as the final SSE result and closes the stream. The
  answer arrives in a new request through the same `handle_input/3` flow.

  For streaming, return `{:noreply, data, :stream}` from `call/2` and implement
  the optional `handle_stream/2` callback:

      def call(%{"to" => to}, _request), do: {:noreply, to, :stream}

      def handle_stream(to, stream) do
        for n <- 1..to, do: Portico.Stream.send(stream, {:progress, n, total: to})
        {:ok, result} = Portico.Result.text("Finished")
        {:ok, result}
      end

  Each invocation chooses its response type. `call/2` runs in the request
  process; keep it short and put long-running work in `handle_stream/2`.
  Portico runs that callback in a linked task and provides the original request
  as `stream.request`. No GenServer, permanent tool process, or session is created.
  The data is an ordinary Elixir value and is not serialized or retained for retries.

  The callback returns `{:ok, %Portico.Result{}}`, including for expected tool
  failures, `{:ok, form, application_state}` to ask for input, or `{:error, reason}`
  when it cannot produce a result. It cannot start
  another stream. Portico stops its task on timeout or detected disconnect. Detached work started by application code is outside
  this task's lifetime; cancellation does not undo effects already performed.
  """

  @doc "Handles tool arguments and chooses an immediate result or streaming work."
  @callback call(map(), Portico.Request.t()) ::
              {:ok, Portico.Result.t()}
              | {:ok, Portico.Input.t(), String.t()}
              | {:error, term()}
              | {:noreply, term(), :stream}

  @doc "Runs request-scoped streaming work and returns the final result."
  @callback handle_stream(term(), Portico.Stream.t()) ::
              {:ok, Portico.Result.t()} | {:ok, Portico.Input.t(), String.t()} | {:error, term()}
  @doc "Handles a validated form reply and state returned by the elicitation verifier."
  @callback handle_input(Portico.Input.answer(), term(), Portico.Request.t()) ::
              {:ok, Portico.Result.t()}
              | {:ok, Portico.Input.t(), String.t()}
              | {:error, term()}
              | {:noreply, term(), :stream}
  @optional_callbacks handle_stream: 2, handle_input: 3

  @doc false
  defmacro __using__(options) do
    quote do
      @behaviour Portico.Tool
      @portico_tool_metadata Portico.Server.Compiler.tool_metadata!(unquote(options), __ENV__)
      @before_compile Portico.Tool
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:call, 2}, :def) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "Portico.Tool requires a public call/2 callback"
    end

    {validator, metadata} =
      env.module |> Module.get_attribute(:portico_tool_metadata) |> Map.pop!(:validator)

    {verifier, metadata} = Map.pop!(metadata, :elicitation_verifier)
    {output_validator, metadata} = Map.pop(metadata, :output_validator)

    quote do
      @doc false
      def __portico_tool__, do: unquote(Macro.escape(metadata))

      @doc false
      def __portico_validator__, do: unquote(Macro.escape(validator))

      @doc false
      def __portico_output_validator__, do: unquote(Macro.escape(output_validator))

      @doc false
      def __portico_verify_input__(state, request),
        do: unquote(Macro.escape(verifier)).(state, request)
    end
  end
end
