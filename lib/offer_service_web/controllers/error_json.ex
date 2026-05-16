defmodule OfferServiceWeb.ErrorJSON do
  @moduledoc false

  @code_for %{
    "400.json" => "bad_request",
    "401.json" => "unauthorized",
    "403.json" => "forbidden",
    "404.json" => "not_found",
    "409.json" => "conflict",
    "422.json" => "unprocessable_entity",
    "500.json" => "internal_server_error",
    "502.json" => "bad_gateway"
  }

  @default_message %{
    "bad_request" => "Bad Request",
    "unauthorized" => "Unauthorized",
    "forbidden" => "Forbidden",
    "not_found" => "Not Found",
    "conflict" => "Conflict",
    "unprocessable_entity" => "Unprocessable Entity",
    "internal_server_error" => "Internal Server Error",
    "bad_gateway" => "Bad Gateway",
    "unknown" => "Unknown error"
  }

  def render(template, assigns) do
    code = Map.get(@code_for, template, "unknown")
    message = Map.get(assigns, :message) || Map.fetch!(@default_message, code)
    %{error: %{code: code, message: message}}
  end
end
