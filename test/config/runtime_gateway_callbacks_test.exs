defmodule OfferService.Config.RuntimeGatewayCallbacksTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @callback_vars ~w(
    GATEWAY_CALLBACK_ENABLED
    GATEWAY_CALLBACK_BASE_URL
    GATEWAY_CALLBACK_PATH
    GATEWAY_CALLBACK_TIMEOUT_MS
    GATEWAY_CALLBACK_ATTEMPTS
    GATEWAY_CALLBACK_LOCALE
  )
  @prod_prereqs %{
    "DATABASE_URL" => "ecto://u:p@localhost/offer_service_runtime_test",
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "INTERNAL_SERVICE_TOKEN" => "runtime-test-token"
  }

  test "disabled is the safe default" do
    config = read_runtime(%{})
    assert config[:enabled] == false
    assert config[:path] == "/svc-callbacks/notify"
    assert config[:timeout_ms] == 5_000
    assert config[:attempts] == 10
  end

  test "valid env values configure the production callback target" do
    config =
      read_runtime(%{
        "GATEWAY_CALLBACK_ENABLED" => "true",
        "GATEWAY_CALLBACK_BASE_URL" => "https://gateway.internal:8443",
        "GATEWAY_CALLBACK_PATH" => "/svc-callbacks/notify",
        "GATEWAY_CALLBACK_TIMEOUT_MS" => "2500",
        "GATEWAY_CALLBACK_ATTEMPTS" => "12",
        "GATEWAY_CALLBACK_LOCALE" => "ar"
      })

    assert config == [
             enabled: true,
             base_url: "https://gateway.internal:8443",
             path: "/svc-callbacks/notify",
             timeout_ms: 2_500,
             attempts: 12,
             locale: "ar"
           ]
  end

  test "production refuses to boot when callbacks are enabled with an invalid URL" do
    assert_raise RuntimeError,
                 ~r/GATEWAY_CALLBACK_BASE_URL must be an absolute http\(s\) URL/,
                 fn ->
                   read_runtime(%{
                     "GATEWAY_CALLBACK_ENABLED" => "true",
                     "GATEWAY_CALLBACK_BASE_URL" => "gateway.internal"
                   })
                 end
  end

  test "invalid path and retry settings fail fast" do
    assert_raise RuntimeError, ~r/GATEWAY_CALLBACK_PATH must start with/, fn ->
      read_runtime(%{
        "GATEWAY_CALLBACK_ENABLED" => "true",
        "GATEWAY_CALLBACK_BASE_URL" => "https://gateway.internal",
        "GATEWAY_CALLBACK_PATH" => "svc-callbacks/notify"
      })
    end

    assert_raise RuntimeError, ~r/GATEWAY_CALLBACK_ATTEMPTS must be a positive integer/, fn ->
      read_runtime(%{"GATEWAY_CALLBACK_ATTEMPTS" => "0"})
    end
  end

  defp read_runtime(overrides) do
    keys = @callback_vars ++ Map.keys(@prod_prereqs)
    saved = Map.new(keys, &{&1, System.get_env(&1)})

    Enum.each(keys, &System.delete_env/1)
    Enum.each(@prod_prereqs, fn {key, value} -> System.put_env(key, value) end)
    Enum.each(overrides, fn {key, value} -> System.put_env(key, value) end)

    try do
      @runtime_config
      |> Config.Reader.read!(env: :prod)
      |> get_in([:offer_service, :gateway_callbacks])
    after
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
