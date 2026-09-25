defmodule SymphonyElixir.Linear.FilterBuilderCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.FilterBuilder

  test "string-keyed config compiles every filter" do
    config = %{
      "labels" => %{"include" => ["symphony"], "exclude" => ["blocked", " "]},
      "teams" => ["GEA", ""],
      "priority" => %{"max" => 2}
    }

    assert FilterBuilder.build(config) == %{
             "and" => [
               %{"priority" => %{"lte" => 2}},
               %{"team" => %{"key" => %{"in" => ["GEA"]}}},
               %{"labels" => %{"name" => %{"in" => ["symphony"]}}},
               %{"labels" => %{"name" => %{"neq" => "blocked"}}}
             ]
           }
  end

  test "string-keyed minimum priority" do
    assert FilterBuilder.build(%{"priority" => %{"min" => 3}}) == %{"priority" => %{"gte" => 3}}
  end

  test "string-keyed bare label list is an include list" do
    assert FilterBuilder.include_labels(%{"labels" => [:symphony, " auto "]}) == ["symphony", "auto"]
    assert FilterBuilder.valid?(%{"teams" => ["GEA"]})
  end

  test "exclusion alone yields a bare AND of NOT conditions" do
    assert FilterBuilder.build(%{labels: %{exclude: ["a", "b"]}}) == %{
             "and" => [
               %{"labels" => %{"name" => %{"neq" => "a"}}},
               %{"labels" => %{"name" => %{"neq" => "b"}}}
             ]
           }
  end

  test "include_labels of a non-map is empty" do
    assert FilterBuilder.include_labels(nil) == []
    assert FilterBuilder.include_labels("symphony") == []
  end
end
