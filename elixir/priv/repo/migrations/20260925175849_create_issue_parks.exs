defmodule SymphonyElixir.Repo.Migrations.CreateIssueParks do
  use Ecto.Migration

  def change do
    # One row each time Symphony parks an issue for a person. A park ends a
    # release: a person moving the issue back out of Shaping starts a new one, and
    # nothing the tester said before the park may gate it (GEA-10531).
    create table(:issue_parks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :issue_identifier, :string, null: false
      add :reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:issue_parks, [:issue_identifier, :inserted_at])
  end
end
