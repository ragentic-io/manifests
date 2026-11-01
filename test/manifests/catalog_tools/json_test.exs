defmodule Manifests.CatalogTools.JsonTest do
  use ExUnit.Case, async: true

  alias Manifests.CatalogTools.{Error, Json, Py}

  describe "canonical/1" do
    test "sorts keys at every level, without whitespace" do
      value = Json.decode!(~s({"b": {"z": 1, "a": [true, null]}, "a": "x", "é": 1, "Z": 2}))
      assert Json.canonical(value) == ~s({"Z":2,"a":"x","b":{"a":[true,null],"z":1},"é":1})
    end

    test "writes non-ASCII as is and escapes like Python's json.dumps(ensure_ascii=False)" do
      assert Json.canonical("é\u2028/\x7f") == ~s("é\u2028/\x7f")
      assert Json.canonical("\"\\\n\r\t\b\f\x01\x1f") == ~S("\"\\\n\r\t\b\f\u0001\u001f")
    end

    test "writes floats with Python's repr" do
      floats = [
        1.0,
        0.1,
        1.0e16,
        1.0e15,
        1.5e16,
        1.0e-5,
        1.0e-4,
        123.456,
        1.0e100,
        -0.0,
        5.0e-324,
        2.5e-7
      ]

      assert Json.canonical(floats) ==
               "[1.0,0.1,1e+16,1000000000000000.0,1.5e+16,1e-05,0.0001,123.456,1e+100,-0.0,5e-324,2.5e-07]"
    end

    test "maps built in code and decoded objects encode the same" do
      decoded = Json.decode!(~s({"kind":"bundle","app":"x","expires":1}))

      assert Json.canonical(decoded) ==
               Json.canonical(%{"app" => "x", "expires" => 1, "kind" => "bundle"})
    end
  end

  describe "pretty/1, compact/1 and dumps/1" do
    test "pretty is indent=2, sort_keys=True with a trailing newline" do
      assert Json.pretty(%{"b" => [], "a" => %{"c" => [1, {:o, []}]}}) ==
               "{\n  \"a\": {\n    \"c\": [\n      1,\n      {}\n    ]\n  },\n  \"b\": []\n}\n"
    end

    test "compact and dumps keep insertion order" do
      obj = Json.decode!(~s({"z": 1, "a": [1, 2]}))
      assert Json.compact(obj) == ~s({"z":1,"a":[1,2]})
      assert Json.dumps(obj) == ~s({"z": 1, "a": [1, 2]})
    end
  end

  describe "decode!/1" do
    test "keeps key order and resolves duplicates like a Python dict" do
      assert Json.decode!(~s({"b": 1, "a": 2, "b": 3})) == {:o, [{"b", 3}, {"a", 2}]}
    end

    test "accepts Python's non-finite floats and big numbers" do
      assert Json.decode!("[NaN, -Infinity, 1e400, 12345678901234567890, -0.0]") ==
               [:nan, :neg_infinity, :infinity, 12_345_678_901_234_567_890, -0.0]
    end

    test "fails with Python's messages" do
      for {text, msg} <- [
            {"", "Expecting value: line 1 column 1 (char 0)"},
            {~s({"a" 1}), "Expecting ':' delimiter: line 1 column 6 (char 5)"},
            {"[1,]", "Illegal trailing comma before end of array: line 1 column 3 (char 2)"},
            {~s({"a":1}x), "Extra data: line 1 column 8 (char 7)"},
            {~s(\n  "é), "Unterminated string starting at: line 2 column 3 (char 3)"}
          ] do
        assert_raise Error, msg, fn -> Json.decode!(text) end
      end
    end
  end

  describe "Python helpers" do
    test "short/1 keeps the first sentence and truncates by code point" do
      assert Py.short("Get a pet.  It returns\n the pet!") == "Get a pet."
      assert Py.short("e.g. this") == "e.g."
      assert Py.short(String.duplicate("ü", 200)) == String.duplicate("ü", 159) <> "…"
      assert Py.short(nil) == nil
    end

    test "repr/1 quotes like Python" do
      assert Py.repr("Tok'en") == ~s("Tok'en")
      assert Py.repr(~s(a'"b)) == ~S('a\'"b')
      assert Py.repr(["x", 1, nil, true, 1.5]) == "['x', 1, None, True, 1.5]"
    end

    test "url_unquote/1 decodes UTF-8 with replacement" do
      assert Py.url_unquote("a%2Fb%C3%A9%E2%82x%ZZé%41") == "a/bé�x%ZZéA"
    end
  end
end
