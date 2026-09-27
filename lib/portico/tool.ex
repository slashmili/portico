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
  Tool input schemas must explicitly declare `type: "object"` at the root;
  `%{}` and non-object or union root types fail compilation. For a tool with no
  arguments, use `%{type: "object", additionalProperties: false}`. Composition
  and local references remain supported alongside the root type. Output schemas
  may describe any JSON type.
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

  Optional `:annotations` is a keyword list of boolean behavior hints:

      annotations: [read_only: true, open_world: false]

  `:read_only` maps to MCP `readOnlyHint` (no environment modification),
  `:destructive` to `destructiveHint` (may perform destructive updates),
  `:idempotent` to `idempotentHint` (identical repeated calls have no additional
  effect), and `:open_world` to `openWorldHint` (may interact with external entities).
  Destructive and idempotent hints are meaningful for non-read-only tools.
  Unknown keys, duplicates and non-booleans fail compilation. An empty list or
  omitted option emits no annotations; unspecified hints are never filled in.
  MCP's interpretation defaults are false, true, false and true respectively.
  These are descriptive hints, not permissions or execution guarantees; clients
  should not trust hints from untrusted servers. Portico does not change tool
  execution based on them. This API covers the four behavior hints, not titles.

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

  For text sampling, build `Portico.Input.sample(prompt, max_tokens: 200)` and
  return `{:ok, input, application_state}`. The client runs its model and retries
  the original tool call; `handle_input/3` receives
  `{:sample, %{text: text, model: model}}`, with optional `:stop_reason`.
  Requires the client's `sampling` capability; missing support returns
  `{:error, :sampling_not_supported}` in tests and `-32021` over HTTP.
  One text block is supported, either directly or in a one-element array.
  Malformed or unsupported answers return invalid params; missing answers reissue
  the sampling input. Streaming callbacks can return sampling inputs too.

  Sampling uses the same `elicitation_key`, five-minute expiry and binding to
  server/tool/arguments, but does not run the elicitation-specific custom verifier.
  Authorize the fresh request in `handle_input/3`; the token does not identify a
  user. No task waits between calls. Clients may decline without retrying, so no
  decline callback is guaranteed. Sampling is deprecated but retained in the
  selected MCP revision. Model preferences, sampling tools and rich content are
  outside this first slice. See `Portico.Input.sample/2`.

  For URL elicitation, build `Portico.Input.url(message, url: url)` and return
  `{:ok, input, application_state}`. URL replies reach `handle_input/3` as
  `:accept`, `:decline`, or `:cancel`, with no content. Acceptance is consent,
  not completion: the application checks its browser workflow and may return
  another input while pending. The application owns storage and browser identity
  checks; never treat a signed continuation as authentication. URL elicitation
  requires the client's `elicitation.url` capability. Missing support returns
  `{:error, :url_not_supported}` in tests and protocol error `-32021` over HTTP.
  URL inputs also work from streaming callbacks and use the same signing key,
  expiry, and optional verifier as forms. See `Portico.Input.url/2`.

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
  @doc "Handles a validated input reply and its verified application state."
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
