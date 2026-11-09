defmodule Sprites.Path do
  @moduledoc false

  # Identifiers occupy exactly one URL path segment. Dot-only segments have
  # routing semantics even though dots are otherwise unreserved characters.
  @spec encode_segment(String.t()) :: String.t()
  def encode_segment(segment) when segment in ["", ".", ".."] do
    raise ArgumentError, "path identifier must not be empty, '.' or '..'"
  end

  def encode_segment(segment) when is_binary(segment) do
    URI.encode(segment, &URI.char_unreserved?/1)
  end
end
