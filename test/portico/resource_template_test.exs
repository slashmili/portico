defmodule Portico.ResourceTemplateTest do
  use ExUnit.Case, async: true
  alias Portico.Resource.Template

  defmodule Section do
    use Portico.Resource, name: "section", mime_type: "text/plain"

    def read(request) do
      send(request.assigns.observer, request)
      Portico.Resource.text(request.resource_params["section"] || "static")
    end
  end

  defmodule Catalog do
    use Portico.Server, name: "templates", version: "1"
    resource_template "company://handbook/{section}", Section
    resource "company://handbook/fixed", Section
  end

  defmodule Overlapping do
    use Portico.Server, name: "overlapping", version: "1"
    resource_template "company://handbook/{section}/fixed", Section
    resource_template "company://handbook/fixed/{section}", Section
  end

  test "routes templates with decoded context, concrete response URIs and static precedence" do
    for {suffix, expected, params} <- [
          {"caf%C3%A9", "café", %{"section" => "café"}},
          {"a%2Fb", "a/b", %{"section" => "a/b"}},
          {"fixed", "static", %{}}
        ] do
      uri = "company://handbook/" <> suffix

      assert {:ok, content} =
               Portico.Test.read_resource(Catalog, uri, assigns: %{observer: self()})

      assert content.text == expected
      assert content.uri == uri
      assert content.mime_type == "text/plain"

      assert_received %Portico.Request{
        resource_uri: ^uri,
        resource_params: ^params,
        server: Catalog
      }
    end

    assert Portico.Test.read_resource(Catalog, "company://handbook/%FF") ==
             {:error, :resource_not_found}
  end

  test "template-only servers advertise resources and list template metadata separately" do
    alias Portico.Protocol.Dispatcher

    assert [%{uri_template: "company://handbook/{section}", module: Section}] =
             Portico.Server.resource_templates(Catalog)

    {:reply, discovery} = Dispatcher.dispatch(Overlapping, message("server/discover"))
    assert discovery["result"]["capabilities"]["resources"] == %{}
    {:reply, listing} = Dispatcher.dispatch(Catalog, message("resources/templates/list"))

    assert listing["result"]["resourceTemplates"] == [
             %{
               "uriTemplate" => "company://handbook/{section}",
               "name" => "section",
               "mimeType" => "text/plain"
             }
           ]

    assert listing["result"]["cacheScope"] == "private"
    assert listing["result"]["ttlMs"] == 0
    {:reply, static} = Dispatcher.dispatch(Catalog, message("resources/list"))
    assert [%{"uri" => "company://handbook/fixed"}] = static["result"]["resources"]

    {:reply, read} =
      Dispatcher.dispatch(
        Catalog,
        message("resources/read", %{"uri" => "company://handbook/leave"}),
        %{observer: self()}
      )

    assert [%{"uri" => "company://handbook/leave", "text" => "leave"}] =
             read["result"]["contents"]
  end

  test "ambiguous matches return errors without invoking a callback" do
    uri = "company://handbook/fixed/fixed"

    assert Portico.Test.read_resource(Overlapping, uri, assigns: %{observer: self()}) ==
             {:error, :ambiguous_resource}

    assert {:reply, %{"error" => %{"code" => -32603}}} =
             Portico.Protocol.Dispatcher.dispatch(
               Overlapping,
               message("resources/read", %{"uri" => uri}),
               %{observer: self()}
             )

    refute_received %Portico.Request{}
  end

  test "unsupported and duplicate template shapes fail at compilation" do
    for routes <- [
          [{"company://handbook/{+section}", Section}],
          [{"company://handbook/{section}", String}],
          [{"company://handbook/{section}", Section}, {"company://handbook/{other}", Section}]
        ] do
      module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

      declarations =
        for {uri, resource} <- routes do
          quote do: resource_template(unquote(uri), unquote(resource))
        end

      assert_raise CompileError, fn ->
        Code.compile_quoted(
          quote do
            defmodule unquote(module) do
              use Portico.Server, name: "invalid", version: "1"
              unquote_splicing(declarations)
            end
          end
        )
      end
    end
  end

  defp message(method, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })
    }
  end

  test "matches whole segments and decodes values once" do
    assert {:ok, template} = Template.build("company://handbook/{section}/{page}")

    assert Template.match(template, "company://handbook/leave/2") ==
             {:ok, %{"section" => "leave", "page" => "2"}}

    assert Template.match(template, "company://handbook/caf%C3%A9/a%2Fb") ==
             {:ok, %{"section" => "café", "page" => "a/b"}}

    assert Template.match(template, "company://handbook/%252F/") ==
             {:ok, %{"section" => "%2F", "page" => ""}}

    for uri <- [
          "company://other/leave/2",
          "company://handbook/a/b/c",
          "company://handbook/a/b?q=x",
          "company://handbook/%FF/b",
          "company://handbook/a+z/b"
        ] do
      assert Template.match(template, uri) == :nomatch
    end
  end

  test "rejects invalid templates and unsupported expansions at build time" do
    for value <- [
          nil,
          "",
          "relative/{x}",
          "company://handbook",
          "company://handbook/{",
          "company://{host}/a",
          "company://a/{x}/{x}",
          "company://a/{x}{y}",
          "company://a/prefix{x}",
          "company://a/{x}.txt",
          "company://a/{+x}",
          "company://a{/x}",
          "company://a{?x}",
          "company://a/{x*}",
          "company://a/{x:2}",
          "company://a/{x,y}"
        ] do
      assert {:error, _} = Template.build(value)
    end
  end
end
