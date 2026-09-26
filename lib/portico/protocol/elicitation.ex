defmodule Portico.Protocol.Elicitation do
  @moduledoc false
  alias Portico.Input
  alias Portico.Protocol.Sampling

  def resume(module, answer, state, request, allowed_modes \\ [:form, :url]) do
    if not function_exported?(module, :handle_input, 3) do
      {:error, :missing_input_callback}
    else
      with {:ok, envelope} <- open_input(state, request),
           true <- envelope.form.mode in allowed_modes,
           :ok <- require_support(request, envelope.form.mode),
           {:ok, answer} <- match_answer(answer, envelope.form),
           {:ok, verified_state} <- verify_input(module, state, request, envelope) do
        case validate_answer(answer, envelope.form) do
          :ok -> module.handle_input(answer, verified_state, request)
          :retry -> {:ok, envelope.form, envelope.state}
        end
      else
        false -> {:input_error, :invalid_params}
        other -> other
      end
    end
  end

  defp open_input(state, request) do
    case Portico.Elicitation.open(state, request) do
      {:error, :invalid_request_state} -> {:input_error, :invalid_request_state}
      other -> other
    end
  end

  defp verify_input(_module, _token, _request, %{form: %Input{mode: :sample}, state: state}),
    do: {:ok, state}

  defp verify_input(module, state, request, _envelope) do
    case module.__portico_verify_input__(state, request) do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      _ -> {:error, :invalid_verifier_return}
    end
  end

  defp validate_answer(:missing, _form), do: :retry

  defp validate_answer({:accept, content}, form) do
    {_schema, validator} = Portico.Schema.build!(form.schema, __ENV__)
    if Portico.Schema.valid?(validator, content), do: :ok, else: :retry
  end

  defp validate_answer(_answer, _form), do: :ok

  def supported?(request, mode \\ :form)

  def supported?(request, :form) do
    case request.client_capabilities["elicitation"] do
      value when is_map(value) and map_size(value) == 0 -> true
      %{"form" => form} when is_map(form) -> true
      _ -> false
    end
  end

  def supported?(request, :sample), do: is_map(request.client_capabilities["sampling"])

  def supported?(request, :url) do
    case request.client_capabilities["elicitation"] do
      %{"url" => url} when is_map(url) -> true
      _ -> false
    end
  end

  def require_support(request, mode) do
    if supported?(request, mode),
      do: :ok,
      else: {:input_error, unsupported_reason(mode)}
  end

  defp unsupported_reason(:sample), do: :sampling_not_supported
  defp unsupported_reason(:url), do: :url_not_supported
  defp unsupported_reason(:form), do: :form_not_supported

  def encode(%Input{mode: :sample}, _state, %{method: method}) when method != "tools/call",
    do: {:error, :invalid_input}

  def encode(%Input{} = input, state, request) do
    with {:ok, input} <- validate_input(input),
         true <- string?(state),
         :ok <- require_support(request, input.mode),
         {:ok, token} <- Portico.Elicitation.seal(input, state, request) do
      mode = Atom.to_string(input.mode)
      input_request = input_request(input)

      {:ok, input,
       %{
         "resultType" => "input_required",
         "requestState" => token,
         "inputRequests" => %{mode => input_request}
       }}
    else
      false -> {:error, :invalid_request_state}
      {:input_error, reason} -> {:error, reason}
      error -> error
    end
  end

  defp input_request(%Input{mode: :sample} = input), do: Sampling.input_request(input)

  defp input_request(input) do
    params = %{"mode" => Atom.to_string(input.mode), "message" => input.message}

    params =
      if input.mode == :url,
        do: Map.put(params, "url", input.url),
        else: Map.put(params, "requestedSchema", input.schema)

    %{"method" => "elicitation/create", "params" => params}
  end

  defp validate_input(%Input{mode: :sample, schema: nil, url: nil} = input),
    do: Input.sample(input.message, max_tokens: input.max_tokens)

  defp validate_input(%Input{mode: :form, url: nil, max_tokens: nil} = input),
    do: Input.form(input.message, schema: input.schema)

  defp validate_input(%Input{mode: :url, schema: nil, max_tokens: nil} = input),
    do: Input.url(input.message, url: input.url)

  defp validate_input(_input), do: {:error, :invalid_input}

  def retry(params) do
    case {Map.fetch(params, "requestState"), Map.fetch(params, "inputResponses")} do
      {:error, :error} ->
        :initial

      {{:ok, state}, responses} ->
        if string?(state), do: answer(responses, state), else: {:error, :invalid_params}

      _ ->
        {:error, :invalid_params}
    end
  end

  defp answer(:error, state), do: {:resume, :missing, state}

  defp answer({:ok, responses}, state) do
    if object?(responses) do
      case Map.take(responses, ["form", "url", "sample"]) |> Map.to_list() do
        [{"form", reply}] ->
          decode(reply, state)

        [{"url", reply}] ->
          decode_url(reply, state)

        [{"sample", reply}] ->
          with {:ok, answer} <- Sampling.decode(reply), do: {:resume, answer, state}

        [] ->
          {:resume, :missing, state}

        _ ->
          {:error, :invalid_params}
      end
    else
      {:error, :invalid_params}
    end
  end

  defp decode_url(%{"action" => action} = reply, state) do
    if object?(reply) and not Map.has_key?(reply, "content") do
      case action do
        "accept" -> {:resume, {:url, :accept}, state}
        "decline" -> {:resume, {:url, :decline}, state}
        "cancel" -> {:resume, {:url, :cancel}, state}
        _ -> {:error, :invalid_params}
      end
    else
      {:error, :invalid_params}
    end
  end

  defp decode_url(_, _), do: {:error, :invalid_params}

  def match_answer(:missing, _input), do: {:ok, :missing}
  def match_answer({:sample, _} = answer, %Input{mode: :sample}), do: {:ok, answer}
  def match_answer({:sample, _}, _input), do: {:input_error, :invalid_params}
  def match_answer(_answer, %Input{mode: :sample}), do: {:input_error, :invalid_params}
  def match_answer({:url, action}, %Input{mode: :url}), do: {:ok, action}
  def match_answer({:url, _}, _input), do: {:input_error, :invalid_params}
  def match_answer(_answer, %Input{mode: :url}), do: {:input_error, :invalid_params}
  def match_answer(answer, %Input{mode: :form}), do: {:ok, answer}

  defp decode(%{"action" => action} = reply, state) do
    content = Map.get(reply, "content", %{})

    if object?(reply) and object?(content) and Enum.all?(content, fn {_, v} -> primitive?(v) end) do
      case action do
        "accept" -> {:resume, {:accept, content}, state}
        "decline" -> {:resume, :decline, state}
        "cancel" -> {:resume, :cancel, state}
        _ -> {:error, :invalid_params}
      end
    else
      {:error, :invalid_params}
    end
  end

  defp decode(_reply, _state), do: {:error, :invalid_params}
  defp primitive?(v) when is_list(v), do: Enum.all?(v, &string?/1)
  defp primitive?(v), do: string?(v) or is_number(v) or is_boolean(v)
  defp object?(v), do: is_map(v) and not is_struct(v) and Enum.all?(Map.keys(v), &string?/1)
  defp string?(v), do: is_binary(v) and String.valid?(v)
end
