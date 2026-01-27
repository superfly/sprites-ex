defmodule Sprites.ErrorTest do
  use ExUnit.Case, async: true

  alias Sprites.Error
  alias Sprites.Error.APIError

  describe "APIError" do
    test "creates basic error" do
      err = %APIError{status: 500, message: "Something went wrong"}
      assert Exception.message(err) == "API error (500): Something went wrong"
    end

    test "creates error with all fields" do
      err = %APIError{
        status: 429,
        message: "Rate limit exceeded",
        body: ~s({"error": "rate_limited"}),
        error_code: "sprite_creation_rate_limited",
        limit: 10,
        window_seconds: 60,
        retry_after_seconds: 30,
        current_count: 5,
        upgrade_available: true,
        upgrade_url: "https://fly.io/upgrade",
        retry_after_header: 25,
        rate_limit_limit: 100,
        rate_limit_remaining: 0,
        rate_limit_reset: 1_706_400_000
      }

      assert err.status == 429
      assert err.error_code == "sprite_creation_rate_limited"
      assert err.limit == 10
      assert err.window_seconds == 60
      assert err.retry_after_seconds == 30
      assert err.current_count == 5
      assert err.upgrade_available == true
      assert err.upgrade_url == "https://fly.io/upgrade"
      assert err.retry_after_header == 25
      assert err.rate_limit_limit == 100
      assert err.rate_limit_remaining == 0
      assert err.rate_limit_reset == 1_706_400_000
    end

    test "message falls back to error_code when message is empty" do
      err = %APIError{status: 429, message: "", error_code: "rate_limited"}
      assert Exception.message(err) == "API error (429): rate_limited"
    end

    test "message falls back to status only when both are empty" do
      err = %APIError{status: 500, message: "", error_code: ""}
      assert Exception.message(err) == "API error (500)"
    end
  end

  describe "APIError.is_rate_limit_error?/1" do
    test "returns true for 429 status" do
      err = %APIError{status: 429, message: "Rate limited"}
      assert APIError.is_rate_limit_error?(err) == true
    end

    test "returns false for non-429 status" do
      err = %APIError{status: 500, message: "Server error"}
      assert APIError.is_rate_limit_error?(err) == false
    end
  end

  describe "APIError.is_creation_rate_limited?/1" do
    test "returns true for creation rate limited error code" do
      err = %APIError{
        status: 429,
        message: "Rate limited",
        error_code: Error.err_code_creation_rate_limited()
      }

      assert APIError.is_creation_rate_limited?(err) == true
    end

    test "returns false for other error codes" do
      err = %APIError{
        status: 429,
        message: "Limit exceeded",
        error_code: Error.err_code_concurrent_limit_exceeded()
      }

      assert APIError.is_creation_rate_limited?(err) == false
    end
  end

  describe "APIError.is_concurrent_limit_exceeded?/1" do
    test "returns true for concurrent limit error code" do
      err = %APIError{
        status: 429,
        message: "Limit exceeded",
        error_code: Error.err_code_concurrent_limit_exceeded()
      }

      assert APIError.is_concurrent_limit_exceeded?(err) == true
    end

    test "returns false for other error codes" do
      err = %APIError{
        status: 429,
        message: "Rate limited",
        error_code: Error.err_code_creation_rate_limited()
      }

      assert APIError.is_concurrent_limit_exceeded?(err) == false
    end
  end

  describe "APIError.get_retry_after_seconds/1" do
    test "prefers JSON retry_after_seconds over header" do
      err = %APIError{
        status: 429,
        message: "Rate limited",
        retry_after_seconds: 30,
        retry_after_header: 60
      }

      assert APIError.get_retry_after_seconds(err) == 30
    end

    test "falls back to header when JSON field is not set" do
      err = %APIError{
        status: 429,
        message: "Rate limited",
        retry_after_header: 60
      }

      assert APIError.get_retry_after_seconds(err) == 60
    end

    test "returns nil when neither is set" do
      err = %APIError{status: 429, message: "Rate limited"}
      assert APIError.get_retry_after_seconds(err) == nil
    end
  end

  describe "Error.parse_api_error/3" do
    test "returns nil for success status codes" do
      assert {:ok, nil} = Error.parse_api_error(200, "OK")
      assert {:ok, nil} = Error.parse_api_error(201, "Created")
      assert {:ok, nil} = Error.parse_api_error(204, "")
      assert {:ok, nil} = Error.parse_api_error(301, "Moved")
      assert {:ok, nil} = Error.parse_api_error(399, "Something")
    end

    test "parses JSON error body" do
      body =
        Jason.encode!(%{
          "error" => "sprite_creation_rate_limited",
          "message" => "Rate limit exceeded",
          "limit" => 10,
          "window_seconds" => 60,
          "retry_after_seconds" => 30,
          "upgrade_available" => true,
          "upgrade_url" => "https://fly.io/upgrade"
        })

      assert {:ok, err} = Error.parse_api_error(429, body)
      assert err.status == 429
      assert err.error_code == "sprite_creation_rate_limited"
      assert err.message == "Rate limit exceeded"
      assert err.limit == 10
      assert err.window_seconds == 60
      assert err.retry_after_seconds == 30
      assert err.upgrade_available == true
      assert err.upgrade_url == "https://fly.io/upgrade"
    end

    test "parses rate limit headers" do
      headers = [
        {"Retry-After", "30"},
        {"X-RateLimit-Limit", "100"},
        {"X-RateLimit-Remaining", "0"},
        {"X-RateLimit-Reset", "1706400000"}
      ]

      body = ~s({"error": "rate_limited", "message": "Too many requests"})

      assert {:ok, err} = Error.parse_api_error(429, body, headers)
      assert err.retry_after_header == 30
      assert err.rate_limit_limit == 100
      assert err.rate_limit_remaining == 0
      assert err.rate_limit_reset == 1_706_400_000
    end

    test "parses lowercase headers" do
      headers = [
        {"retry-after", "30"},
        {"x-ratelimit-limit", "100"}
      ]

      body = ~s({"message": "Rate limited"})

      assert {:ok, err} = Error.parse_api_error(429, body, headers)
      assert err.retry_after_header == 30
      assert err.rate_limit_limit == 100
    end

    test "handles non-JSON body" do
      body = "Internal Server Error: something went wrong"

      assert {:ok, err} = Error.parse_api_error(500, body)
      assert err.status == 500
      assert err.message == body
      assert err.error_code == nil
    end

    test "handles empty body" do
      assert {:ok, err} = Error.parse_api_error(500, "")
      assert err.status == 500
      assert err.message =~ "API error"
    end

    test "handles invalid header values gracefully" do
      headers = [
        {"Retry-After", "not-a-number"},
        {"X-RateLimit-Limit", "invalid"}
      ]

      body = ~s({"message": "Error"})

      assert {:ok, err} = Error.parse_api_error(429, body, headers)
      assert err.retry_after_header == nil
      assert err.rate_limit_limit == nil
    end

    test "parses concurrent limit error" do
      body =
        Jason.encode!(%{
          "error" => "concurrent_sprite_limit_exceeded",
          "message" => "Too many concurrent sprites",
          "current_count" => 5,
          "limit" => 5
        })

      assert {:ok, err} = Error.parse_api_error(429, body)
      assert err.error_code == Error.err_code_concurrent_limit_exceeded()
      assert err.current_count == 5
      assert err.limit == 5
      assert APIError.is_concurrent_limit_exceeded?(err) == true
    end
  end

  describe "error code constants" do
    test "creation rate limited code" do
      assert Error.err_code_creation_rate_limited() == "sprite_creation_rate_limited"
    end

    test "concurrent limit exceeded code" do
      assert Error.err_code_concurrent_limit_exceeded() == "concurrent_sprite_limit_exceeded"
    end
  end
end
