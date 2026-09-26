defmodule Portico.Protocol.Dispatcher do
  @moduledoc false
  require Logger

  alias Portico.{Input, Request, Result, Schema, Server}
  alias Portico.Protocol.{Elicitation, Encoder, Error, Resources, Validation}

  @supported_versions ["2026-07-28"]

  @doc """
  Processes a decoded protocol message through the current validation stages.

  Returns a JSON-ready reply, a deferred stream execution, or `:no_response`
  for a valid notification.
  Optional application assigns are copied into the fresh request context.
  Envelope errors take precedence over request metadata errors. Notifications
  are ignored; no notification handlers are implemented yet.

  Checks the protocol version on every request before method lookup. Currently
  `server/discover`, tool listing/calling, and static text resource listing/reading
  are implemented, including
  text and structured results, form elicitation, and request-scoped streaming.
  Discovery advertises basic tools support and resources when declared. Listing returns the whole
  static catalog in name order and issues no pagination cursors. Discovery and
  listing use private cache scope with zero TTL (immediately stale). Known client
  metadata is validated; trace-context extraction and propagation are deferred.
  Arguments are validated before callback execution without
  coercion; schema failures return a completed tool error. Test helpers use `call_tool_request/3`
  for the same validation and execution with exceptions left visible to tests.
  """
  @spec dispatch(module(), term(), map()) :: {:reply, map()} | {:stream, map()} | :no_response
  def dispatch(server, message, assigns \\ %{}) when is_map(assigns) do
    case prepare(message, assigns) do
      {:ok, message, context} -> dispatch_method(server, message, context)
      :no_response -> :no_response
      {:error, reason} -> {:reply, Error.response(reason, readable_id(message))}
    end
  end

  @doc false
  def call_tool_request(server, message, assigns) do
    case prepare(message, assigns) do
      {:ok, %{"method" => "tools/call", "params" => params}, context} ->
        case execute_call(server, params, context) do
          {:ok, result, _fields} -> {:ok, result}
          {:input, form, state, _fields} -> {:ok, form, state}
          {:input_error, reason} -> {:error, reason}
          {:callback_error, reason} -> {:error, reason}
          {:stream, _} = stream -> stream
          {:error, _reason} = error -> error
        end

      {:ok, _message, _context} ->
        {:error, :method_not_found}

      :no_response ->
        {:error, :invalid_request}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  def read_resource_request(server, message, assigns) do
    case prepare(message, assigns) do
      {:ok, %{"method" => "resources/read", "params" => params}, context} ->
        case Resources.read(server, params, context) do
          {:ok, content, _fields} -> {:ok, content}
          {:callback_error, reason} -> {:error, reason}
          error -> error
        end

      {:ok, _, _} ->
        {:error, :method_not_found}

      :no_response ->
        {:error, :invalid_request}

      error ->
        error
    end
  end

  defp prepare(message, assigns) do
    case Validation.envelope(message) do
      {:error, :invalid_request} = error ->
        error

      {:ok, :notification, _notification} ->
        :no_response

      {:ok, :request, request} ->
        params = Map.get(request, "params", %{})

        with {:ok, metadata} <- Validation.request_metadata(params) do
          version = metadata["io.modelcontextprotocol/protocolVersion"]

          if version in @supported_versions do
            context = %Request{
              id: request["id"],
              method: request["method"],
              protocol_version: version,
              client_info: metadata["io.modelcontextprotocol/clientInfo"],
              progress_token: metadata["progressToken"],
              client_capabilities: metadata["io.modelcontextprotocol/clientCapabilities"],
              assigns: assigns
            }

            {:ok, request, context}
          else
            {:error, {:unsupported_protocol_version, version, @supported_versions}}
          end
        end
    end
  end

  defp dispatch_method(server, %{"method" => "server/discover", "id" => id}, _context) do
    complete(server, id, %{
      "supportedVersions" => @supported_versions,
      "cacheScope" => "private",
      "ttlMs" => 0,
      "capabilities" =>
        if(Server.resources(server) == [],
          do: %{"tools" => %{}},
          else: %{"tools" => %{}, "resources" => %{}}
        )
    })
  end

  defp dispatch_method(
         server,
         %{"method" => "tools/list", "id" => id, "params" => params},
         _context
       ) do
    if Map.has_key?(params, "cursor") do
      {:reply, Error.response(:invalid_params, id)}
    else
      tools = Enum.map(Server.tools(server), &tool_metadata/1)
      complete(server, id, %{"tools" => tools, "cacheScope" => "private", "ttlMs" => 0})
    end
  end

  defp dispatch_method(server, %{"method" => "tools/call", "params" => params}, context) do
    invoke(server, params, context)
  end

  defp dispatch_method(server, %{"method" => method, "params" => params, "id" => id}, _context)
       when method in ["resources/list", "resources/templates/list"] do
    if Map.has_key?(params, "cursor") do
      {:reply, Error.response(:invalid_params, id)}
    else
      {key, items} =
        if method == "resources/list",
          do: {"resources", Enum.map(Server.resources(server), &Resources.metadata/1)},
          else: {"resourceTemplates", []}

      complete(server, id, %{key => items, "cacheScope" => "private", "ttlMs" => 0})
    end
  end

  defp dispatch_method(server, %{"method" => "resources/read", "params" => params}, context) do
    read_resource(server, params, context)
  end

  defp dispatch_method(_server, request, _context) do
    {:reply, Error.response(:method_not_found, request["id"])}
  end

  defp read_resource(server, params, context) do
    case Resources.read(server, params, context) do
      {:ok, _content, fields} ->
        complete(server, context.id, fields)

      {:error, reason} when reason in [:invalid_params, :resource_not_found] ->
        {:reply, Error.response(:invalid_params, context.id)}

      _ ->
        {:reply, Error.response(:internal_error, context.id)}
    end
  rescue
    _ -> {:reply, Error.response(:internal_error, context.id)}
  end

  defp invoke(server, params, request) do
    case execute_call(server, params, request) do
      {:error, reason} when reason in [:unknown_tool, :invalid_params] ->
        {:reply, Error.response(:invalid_params, request.id)}

      {:input_error, reason} when reason in [:form_not_supported, :url_not_supported] ->
        {:reply, Error.response(reason, request.id)}

      {:input_error, _reason} ->
        {:reply, Error.response(:invalid_params, request.id)}

      {:callback_error, reason} ->
        Logger.error(fn -> "Portico tool callback failed: #{inspect(reason)}" end)
        {:reply, Error.response(:internal_error, request.id)}

      {:error, _reason} ->
        {:reply, Error.response(:internal_error, request.id)}

      {:input, _form, _state, fields} ->
        input_required(server, request.id, fields)

      {:ok, _result, fields} ->
        complete(server, request.id, fields)

      {:stream, execution} ->
        {:stream, execution}
    end
  rescue
    _error -> {:reply, Error.response(:internal_error, request.id)}
  end

  defp execute_call(server, params, request) do
    with {:ok, name, arguments} <- Validation.tool_call(params) do
      request = %{request | server: server, tool_name: name, arguments: arguments}

      case invoke_tool(server, name, arguments, request, Elicitation.retry(params)) do
        {:ok, %Result{} = result} ->
          case Encoder.tool_result(result) do
            {:ok, fields} -> {:ok, result, fields}
            {:error, _} = error -> error
          end

        {:ok, %Input{} = form, state} ->
          input_result(form, state, request)

        outcome ->
          outcome
      end
    end
  end

  @doc false
  def input_result(form, state, request) do
    case Elicitation.encode(form, state, request) do
      {:ok, form, fields} ->
        {:input, form, fields["requestState"], fields}

      {:error, reason} when reason in [:form_not_supported, :url_not_supported] ->
        {:input_error, reason}

      error ->
        error
    end
  end

  @doc false
  def input_required(server, id, fields),
    do: response(server, id, Map.put(fields, "resultType", "input_required"))

  defp tool_metadata(tool) do
    metadata = %{"name" => tool.name, "inputSchema" => tool.input_schema}

    metadata =
      if Map.has_key?(tool, :output_schema),
        do: Map.put(metadata, "outputSchema", tool.output_schema),
        else: metadata

    case Map.fetch(tool, :description) do
      {:ok, description} -> Map.put(metadata, "description", description)
      :error -> metadata
    end
  end

  @doc false
  def complete(server, id, fields),
    do: response(server, id, Map.put(fields, "resultType", "complete"))

  defp response(server, id, fields) do
    info = Server.info(server)

    {:reply,
     %{
       "jsonrpc" => "2.0",
       "id" => id,
       "result" =>
         Map.merge(fields, %{
           "_meta" => %{
             "io.modelcontextprotocol/serverInfo" => %{
               "name" => info.name,
               "version" => info.version
             }
           }
         })
     }}
  end

  defp readable_id(%{"id" => id}) when is_integer(id), do: id

  defp readable_id(%{"id" => id}) when is_binary(id) do
    if String.valid?(id), do: id, else: nil
  end

  defp readable_id(_message), do: nil

  @spec call_tool(module(), String.t(), map(), Request.t()) ::
          {:ok, Result.t()} | {:ok, Input.t(), String.t()} | {:stream, map()} | {:error, term()}
  def call_tool(server, name, arguments, %Request{} = request) do
    with {:ok, name, arguments} <-
           Validation.tool_call(%{"name" => name, "arguments" => arguments}) do
      case invoke_tool(server, name, arguments, request) do
        {:callback_error, reason} -> {:error, reason}
        outcome -> outcome
      end
    end
  end

  def call_tool(_server, _name, _arguments, _request), do: {:error, :invalid_params}

  defp invoke_tool(server, name, arguments, request, retry \\ :initial)
  defp invoke_tool(_server, _name, _arguments, _request, {:error, _} = error), do: error

  defp invoke_tool(server, name, arguments, request, retry) do
    case Enum.find(Server.tools(server), &(&1.name == name)) do
      nil ->
        {:error, :unknown_tool}

      %{module: module} ->
        case Schema.validate(module.__portico_validator__(), arguments) do
          :ok ->
            case run_callback(module, arguments, request, retry) do
              {:ok, %Input{} = form, state} ->
                if function_exported?(module, :handle_input, 3),
                  do: {:ok, form, state},
                  else: {:error, :missing_input_callback}

              {:ok, %Result{} = result} = reply ->
                case Encoder.tool_result(result, module.__portico_output_validator__()) do
                  {:ok, _fields} -> reply
                  {:error, _} = error -> error
                end

              {:input_error, _} = error ->
                error

              {:error, reason} ->
                {:callback_error, reason}

              {:noreply, data, :stream} ->
                if function_exported?(module, :handle_stream, 2) do
                  {:stream, %{module: module, data: data, request: request, server: server}}
                else
                  {:error, :missing_stream_callback}
                end

              _other ->
                {:error, :invalid_callback_return}
            end

          {:error, message} ->
            Result.error(message)
        end
    end
  end

  defp run_callback(module, arguments, request, :initial), do: module.call(arguments, request)

  defp run_callback(module, _arguments, request, {:resume, answer, state}) do
    if not function_exported?(module, :handle_input, 3) do
      {:error, :missing_input_callback}
    else
      with {:ok, envelope} <- open_input(state, request),
           :ok <- Elicitation.require_support(request, envelope.form.mode),
           {:ok, answer} <- Elicitation.match_answer(answer, envelope.form),
           {:ok, verified_state} <- verify_input(module, state, request) do
        case validate_answer(answer, envelope.form) do
          :ok -> module.handle_input(answer, verified_state, request)
          :retry -> {:ok, envelope.form, envelope.state}
        end
      end
    end
  end

  defp open_input(state, request) do
    case Portico.Elicitation.open(state, request) do
      {:error, :invalid_request_state} -> {:input_error, :invalid_request_state}
      other -> other
    end
  end

  defp verify_input(module, state, request) do
    case module.__portico_verify_input__(state, request) do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      _ -> {:error, :invalid_verifier_return}
    end
  end

  defp validate_answer(:missing, _form), do: :retry

  defp validate_answer({:accept, content}, form) do
    {_schema, validator} = Schema.build!(form.schema, __ENV__)
    if Schema.valid?(validator, content), do: :ok, else: :retry
  end

  defp validate_answer(_answer, _form), do: :ok
end
