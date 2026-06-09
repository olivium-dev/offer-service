defmodule OfferService.PromExTest do
  use ExUnit.Case

  describe "PromEx configuration" do
    test "has required plugins configured" do
      plugins = OfferService.PromEx.plugins()

      plugin_modules =
        Enum.map(plugins, fn
          {module, _opts} -> module
          module -> module
        end)

      # Verify standard plugins are present
      assert PromEx.Plugins.Application in plugin_modules
      assert PromEx.Plugins.Beam in plugin_modules
      assert PromEx.Plugins.Oban in plugin_modules

      # Verify Phoenix plugin with router config
      phoenix_config =
        Enum.find(plugins, fn
          {PromEx.Plugins.Phoenix, _opts} -> true
          _ -> false
        end)

      assert phoenix_config != nil

      # Verify Ecto plugin with repos config
      ecto_config =
        Enum.find(plugins, fn
          {PromEx.Plugins.Ecto, _opts} -> true
          _ -> false
        end)

      assert ecto_config != nil
    end

    test "has dashboard assignments configured" do
      assigns = OfferService.PromEx.dashboard_assigns()
      assert assigns[:datasource_id] == "prometheus_datasource"
      assert assigns[:default_selected_interval] == "30s"
    end

    test "has dashboards configured" do
      dashboards = OfferService.PromEx.dashboards()
      assert {:prom_ex, "application.json"} in dashboards
      assert {:prom_ex, "beam.json"} in dashboards
      assert {:prom_ex, "phoenix.json"} in dashboards
    end
  end
end
