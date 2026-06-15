defmodule OfferService.Config.RuntimeServiceTokenTest do
  @moduledoc """
  Regression guard for the `:service_token` wiring in `config/runtime.exs`.

  `:service_token` is the shared internal key that `OfferServiceWeb.Plugs.ServiceAuth`
  compares against `X-Service-Auth-Key` to gate the S07/N3 force-expire test-seam.
  The plug fails closed: a `nil`/blank configured token rejects every request (401).

  The runtime resolution of this key has security-relevant branches that are
  otherwise *unreachable* from ExUnit (the non-prod block is skipped under
  `MIX_ENV=test`, and the prod block only runs under `MIX_ENV=prod`). We evaluate
  the config file directly with `Config.Reader.read!/2`, passing `env:` explicitly,
  which exercises each branch without booting the app or a prod release. This pins:

    * dev honors a present `INTERNAL_SERVICE_TOKEN` (the bug this seam fixed),
    * dev treats unset / "" as unset → `nil` → plug fails closed (default-off),
    * `:test` is left untouched (token comes from `config/test.exs`),
    * **prod refuses to boot without a token** — the invariant proving this change
      did not weaken prod auth.

  `async: false`: these cases mutate the process-global `INTERNAL_SERVICE_TOKEN`
  env var. Each helper saves and restores the prior value so the suite stays
  hermetic, but the module must not run concurrently with anything else that
  reads that var.
  """
  use ExUnit.Case, async: false

  @env_var "INTERNAL_SERVICE_TOKEN"
  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  # The :prod block in runtime.exs raises on DATABASE_URL / SECRET_KEY_BASE
  # *before* it reaches the :service_token logic. Provision throwaway values so
  # an :prod read exercises the token branch rather than tripping an earlier guard.
  @prod_prereqs %{
    "DATABASE_URL" => "ecto://u:p@localhost/offer_service_runtime_test",
    "SECRET_KEY_BASE" => String.duplicate("x", 64)
  }

  # Evaluate config/runtime.exs for `env` with INTERNAL_SERVICE_TOKEN set to
  # `value` (nil = unset), returning the resolved :offer_service :service_token.
  # Restores all touched env vars afterwards so the test leaves no global residue.
  defp resolve_service_token(env, value) do
    prereqs = if env == :prod, do: @prod_prereqs, else: %{}
    saved = save_env([@env_var | Map.keys(prereqs)])

    set_env(@env_var, value)
    Enum.each(prereqs, fn {k, v} -> set_env(k, v) end)

    try do
      @runtime_config
      |> Config.Reader.read!(env: env)
      |> get_in([:offer_service, :service_token])
    after
      restore_env(saved)
    end
  end

  defp save_env(keys), do: Map.new(keys, fn k -> {k, System.get_env(k)} end)
  defp restore_env(saved), do: Enum.each(saved, fn {k, v} -> set_env(k, v) end)

  defp set_env(key, nil), do: System.delete_env(key)
  defp set_env(key, value), do: System.put_env(key, value)

  describe "dev (non-prod) honors INTERNAL_SERVICE_TOKEN" do
    test "present token => configured (the seam is reachable)" do
      assert resolve_service_token(:dev, "dev-service-key") == "dev-service-key"
    end

    test "unset => nil (default-off; ServiceAuth fails closed)" do
      assert resolve_service_token(:dev, nil) == nil
    end

    test "empty string => nil (treated as unset; fails closed)" do
      assert resolve_service_token(:dev, "") == nil
    end
  end

  describe ":test env is excluded" do
    test "the non-prod block does not wire the token, even when the env var is set" do
      # config/runtime.exs sets nothing for :service_token under :test, so the
      # base config (which never sets the key) yields nil here. The real test
      # token lives in config/test.exs (compile-time), not in runtime.exs.
      assert resolve_service_token(:test, "ignored-in-test") == nil
    end
  end

  describe "prod hard-fails without a token" do
    test "missing token raises so prod refuses to boot" do
      assert_raise RuntimeError, ~r/INTERNAL_SERVICE_TOKEN is required/, fn ->
        resolve_service_token(:prod, nil)
      end
    end

    test "present token => configured (prod block is the authoritative writer)" do
      assert resolve_service_token(:prod, "prod-service-key") == "prod-service-key"
    end
  end
end
