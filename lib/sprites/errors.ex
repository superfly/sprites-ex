defmodule Sprites.Error do
  @moduledoc """
  Error types for the Sprites SDK.
  """

  @doc "Error code for sprite creation rate limit"
  def err_code_creation_rate_limited, do: "sprite_creation_rate_limited"

  @doc "Error code for concurrent sprite limit exceeded"
  def err_code_concurrent_limit_exceeded, do: "concurrent_sprite_limit_exceeded"

  defmodule APIError do
    @moduledoc """
    Raised when the API returns an error response.

    Provides detailed information about rate limits and other API errors.
    """
    defexception [
      :status,
      :message,
      :body,
      # Structured fields from JSON body
      :error_code,
      :limit,
      :window_seconds,
      :retry_after_seconds,
      :current_count,
      :upgrade_available,
      :upgrade_url,
      # Fields from HTTP headers
      :retry_after_header,
      :rate_limit_limit,
      :rate_limit_remaining,
      :rate_limit_reset
    ]

    @type t :: %__MODULE__{
            status: integer() | nil,
            message: String.t() | nil,
            body: String.t() | nil,
            error_code: String.t() | nil,
            limit: integer() | nil,
            window_seconds: integer() | nil,
            retry_after_seconds: integer() | nil,
            current_count: integer() | nil,
            upgrade_available: boolean() | nil,
            upgrade_url: String.t() | nil,
            retry_after_header: integer() | nil,
            rate_limit_limit: integer() | nil,
            rate_limit_remaining: integer() | nil,
            rate_limit_reset: integer() | nil
          }

    @impl true
    def message(%{status: status, message: msg}) when is_binary(msg) and msg != "" do
      "API error (#{status}): #{msg}"
    end

    def message(%{status: status, error_code: code}) when is_binary(code) and code != "" do
      "API error (#{status}): #{code}"
    end

    def message(%{status: status}) do
      "API error (#{status})"
    end

    @doc "Returns true if this is a 429 rate limit error"
    @spec is_rate_limit_error?(t()) :: boolean()
    def is_rate_limit_error?(%__MODULE__{status: 429}), do: true
    def is_rate_limit_error?(%__MODULE__{}), do: false

    @doc "Returns true if this is a sprite creation rate limit error"
    @spec is_creation_rate_limited?(t()) :: boolean()
    def is_creation_rate_limited?(%__MODULE__{error_code: code}) do
      code == Sprites.Error.err_code_creation_rate_limited()
    end

    @doc "Returns true if this is a concurrent sprite limit error"
    @spec is_concurrent_limit_exceeded?(t()) :: boolean()
    def is_concurrent_limit_exceeded?(%__MODULE__{error_code: code}) do
      code == Sprites.Error.err_code_concurrent_limit_exceeded()
    end

    @doc """
    Returns the number of seconds to wait before retrying.
    Prefers the JSON field, falling back to the header value.
    """
    @spec get_retry_after_seconds(t()) :: integer() | nil
    def get_retry_after_seconds(%__MODULE__{retry_after_seconds: seconds})
        when is_integer(seconds) and seconds > 0 do
      seconds
    end

    def get_retry_after_seconds(%__MODULE__{retry_after_header: seconds})
        when is_integer(seconds) do
      seconds
    end

    def get_retry_after_seconds(%__MODULE__{}), do: nil
  end

  @doc """
  Parse a structured API error from an HTTP response.

  Returns `{:ok, %APIError{}}` if status >= 400, `{:ok, nil}` otherwise.
  """
  @spec parse_api_error(integer(), binary(), list()) :: {:ok, APIError.t() | nil}
  def parse_api_error(status, body, headers \\ [])

  def parse_api_error(status, _body, _headers) when status < 400 do
    {:ok, nil}
  end

  def parse_api_error(status, body, headers) when status >= 400 do
    headers_map =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
      |> Map.new()

    # Parse rate limit headers
    retry_after_header = parse_int_header(headers_map, "retry-after")
    rate_limit_limit = parse_int_header(headers_map, "x-ratelimit-limit")
    rate_limit_remaining = parse_int_header(headers_map, "x-ratelimit-remaining")
    rate_limit_reset = parse_int_header(headers_map, "x-ratelimit-reset")

    # Try to parse JSON body
    {error_code, message, limit, window_seconds, retry_after_seconds, current_count,
     upgrade_available,
     upgrade_url} =
      case Jason.decode(body) do
        {:ok, data} when is_map(data) ->
          {
            Map.get(data, "error"),
            Map.get(data, "message"),
            Map.get(data, "limit"),
            Map.get(data, "window_seconds"),
            Map.get(data, "retry_after_seconds"),
            Map.get(data, "current_count"),
            Map.get(data, "upgrade_available", false),
            Map.get(data, "upgrade_url")
          }

        _ ->
          # Use raw body as message
          {nil, body, nil, nil, nil, nil, false, nil}
      end

    # Fallback message if nothing was parsed
    final_message =
      cond do
        is_binary(message) and message != "" -> message
        is_binary(error_code) and error_code != "" -> error_code
        true -> "API error (status #{status})"
      end

    {:ok,
     %APIError{
       status: status,
       message: final_message,
       body: body,
       error_code: error_code,
       limit: limit,
       window_seconds: window_seconds,
       retry_after_seconds: retry_after_seconds,
       current_count: current_count,
       upgrade_available: upgrade_available,
       upgrade_url: upgrade_url,
       retry_after_header: retry_after_header,
       rate_limit_limit: rate_limit_limit,
       rate_limit_remaining: rate_limit_remaining,
       rate_limit_reset: rate_limit_reset
     }}
  end

  defp parse_int_header(headers, key) do
    case Map.get(headers, key) do
      nil -> nil
      value -> String.to_integer(value)
    end
  rescue
    _ -> nil
  end

  defmodule CommandError do
    @moduledoc "Raised when a command fails with non-zero exit code."
    defexception [:exit_code, :stderr]

    @impl true
    def message(%{exit_code: code}) do
      "Command exited with code #{code}"
    end
  end

  defmodule ConnectionError do
    @moduledoc "Raised when WebSocket connection fails."
    defexception [:reason]

    @impl true
    def message(%{reason: reason}) do
      "WebSocket connection failed: #{inspect(reason)}"
    end
  end

  defmodule TimeoutError do
    @moduledoc "Raised when an operation times out."
    defexception [:timeout]

    @impl true
    def message(%{timeout: timeout}) do
      "Operation timed out after #{timeout}ms"
    end
  end

  defmodule FilesystemError do
    @moduledoc "Raised when a filesystem operation fails."
    defexception [:reason, :path]

    @impl true
    def message(%{reason: :enoent, path: path}) do
      "File or directory not found: #{path}"
    end

    def message(%{reason: {:api_error, status, body}, path: path}) do
      "Filesystem error (#{status}) for #{path}: #{inspect(body)}"
    end

    def message(%{reason: reason, path: path}) do
      "Filesystem error for #{path}: #{inspect(reason)}"
    end
  end
end
