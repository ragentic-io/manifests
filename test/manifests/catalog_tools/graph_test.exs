defmodule Manifests.CatalogTools.GraphTest do
  use ExUnit.Case, async: true

  alias Manifests.CatalogTools.{Graph, Json}

  @document ~S"""
  {
    "openapi": "3.0.0",
    "paths": {
      "/pets/{id}": {
        "parameters": [{"name": "id", "in": "path", "schema": {"type": "string"}}],
        "get": {
          "operationId": "getPet",
          "summary": "Get a pet.",
          "parameters": [{"$ref": "#/components/parameters/Verbose"}],
          "responses": {
            "200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Pet"}}}},
            "404": {"description": "missing"}
          }
        },
        "delete": {
          "description": "Delete a pet. Irreversible.",
          "requestBody": {"content": {"application/json": {"schema": {"$ref": "#/components/schemas/Owner"}}}},
          "responses": {"204": {"description": "gone"}}
        }
      }
    },
    "components": {
      "parameters": {"Verbose": {"name": "verbose", "in": "query", "schema": {"type": "boolean", "default": false}}},
      "schemas": {
        "Pet": {"type": "object", "properties": {"owner": {"$ref": "#/components/schemas/Owner"}}},
        "Owner": {"type": "object", "description": "A person.  Who owns pets."}
      }
    }
  }
  """

  setup do
    %{graph: Graph.openapi_graph("pets", Json.decode!(@document))}
  end

  test "nodes: the application, operations in document order, then schemas", %{graph: graph} do
    assert Enum.map(graph["nodes"], & &1["id"]) == [
             "pets",
             "operation:get:/pets/{id}",
             "operation:delete:/pets/{id}",
             "schema:Pet",
             "schema:Owner"
           ]

    [_, get, delete, pet, owner] = graph["nodes"]

    assert get == %{
             "id" => "operation:get:/pets/{id}",
             "kind" => "operation",
             "deprecated" => false,
             "method" => "get",
             "name" => "getPet",
             "path" => "/pets/{id}",
             "pointer" => "#/paths/~1pets~1{id}/get",
             "safe" => true,
             "security" => [],
             "summary" => "Get a pet.",
             "parameters" => [
               %{"name" => "id", "in" => "path", "required" => true, "type" => "string"},
               %{
                 "name" => "verbose",
                 "in" => "query",
                 "required" => false,
                 "type" => "boolean",
                 "default" => false
               }
             ],
             "responses" => [%{"status" => "200", "type" => "Pet"}, %{"status" => "404"}]
           }

    assert delete["name"] == "delete /pets/{id}"
    assert delete["safe"] == false
    assert delete["summary"] == nil
    assert delete["description"] == "Delete a pet."

    assert delete["request"] == %{
             "content_types" => ["application/json"],
             "required" => false,
             "type" => "Owner"
           }

    assert pet == %{"id" => "schema:Pet", "kind" => "schema", "name" => "Pet", "type" => "object"}
    assert owner["description"] == "A person."
  end

  test "edges: EXPOSES first, then ACCEPTS/RETURNS per operation, then REFERENCES", %{
    graph: graph
  } do
    assert graph["edges"] == [
             %{"from" => "pets", "kind" => "EXPOSES", "to" => "operation:get:/pets/{id}"},
             %{"from" => "pets", "kind" => "EXPOSES", "to" => "operation:delete:/pets/{id}"},
             %{"from" => "operation:get:/pets/{id}", "kind" => "RETURNS", "to" => "schema:Pet"},
             %{
               "from" => "operation:delete:/pets/{id}",
               "kind" => "ACCEPTS",
               "to" => "schema:Owner"
             },
             %{"from" => "schema:Pet", "kind" => "REFERENCES", "to" => "schema:Owner"}
           ]
  end

  test "sorted_graph/1 ignores order, so a decoded copy compares equal", %{graph: graph} do
    reordered = %{
      "nodes" => Enum.reverse(graph["nodes"]),
      "edges" => Enum.reverse(graph["edges"])
    }

    assert Graph.sorted_graph(Json.decode!(Json.pretty(reordered))) == Graph.sorted_graph(graph)
  end

  test "compact types" do
    refs = MapSet.new()
    type = fn json -> json |> Json.decode!() |> Graph.type(refs) |> elem(0) end

    assert type.(~s({"type": "array", "items": {"$ref": "#/definitions/Pet"}})) == "Pet[]"
    assert type.(~s({"type": ["string", "null"], "format": "date-time"})) == "string:date-time"

    assert type.(
             ~s({"oneOf": [{"$ref": "#/components/schemas/A"}, {"$ref": "#/components/schemas/A"}, {"type": "integer"}]})
           ) == "A|integer"

    assert type.(~s({"properties": {"a": {}}})) == "object"
    assert type.(~s({"type": "array"})) == "array"
    assert type.(~s({})) == nil
  end
end
