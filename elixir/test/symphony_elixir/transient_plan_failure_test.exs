defmodule SymphonyElixir.TransientPlanFailureTest do
  # GEA-10595: a cold Claude start wrote its transcript 31.7 s after launch, past the 30 s
  # wait. The planner read `:not_found`, and a healthy issue (GEA-10456) parked in
  # Shaping. A slow start is a startup blip; the next poll retries it.
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator

  test "a transcript that did not appear in time is transient" do
    assert Orchestrator.transient_plan_failure?({:plan_assess_failed, :not_found})
  end

  test "a session that did not start is transient" do
    assert Orchestrator.transient_plan_failure?({:plan_assess_failed, {:start_session_failed, :ready_timeout}})
  end

  test "any other plan failure still parks for a person" do
    refute Orchestrator.transient_plan_failure?({:plan_assess_failed, {:turn_failed, :timeout}})
    refute Orchestrator.transient_plan_failure?({:plan_assess_failed, :invalid_json})
    refute Orchestrator.transient_plan_failure?({:plan_action_crashed, "boom"})
    refute Orchestrator.transient_plan_failure?(:not_found)
  end
end
