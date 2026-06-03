defmodule OfferServiceWeb.ErrorJSON do
  @moduledoc false

  @default_code_for %{
    "400.json" => "bad_request",
    "401.json" => "unauthorized",
    "403.json" => "forbidden",
    "404.json" => "not_found",
    "409.json" => "conflict",
    "410.json" => "gone",
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
    "gone" => "Gone",
    "unprocessable_entity" => "Unprocessable Entity",
    "edit_limit_reached" => "Edit limit reached",
    "offer_withdrawn" => "Offer has been withdrawn",
    "offer_expired" => "Offer has expired",
    "already_accepted" => "Already accepted",
    "already_rejected" => "Already rejected",
    "invalid_transition" => "Invalid transition",
    "validation_failed" => "Validation failed",
    "internal_server_error" => "Internal Server Error",
    "bad_gateway" => "Bad Gateway",
    "unknown" => "Unknown error"
  }

  def render(template, assigns) do
    code = Map.get(assigns, :code) || Map.get(@default_code_for, template, "unknown")
    message = Map.get(assigns, :message) || Map.get(@default_message, code, "Unknown error")
    %{error: %{code: code, message: message}}
  end
end
