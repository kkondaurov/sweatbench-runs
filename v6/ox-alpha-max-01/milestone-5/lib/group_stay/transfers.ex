defmodule GroupStay.Transfers do
  @moduledoc """
  Moves applied deposit funding between two active groups of the same guest.

  A transfer redraws `amount_cents` of the source's held funding — cash and
  hotel credit alike, whatever their provenance — in reverse allocation
  order (most recently created allocation first) and refills the
  destination's active rooms in their original order, preserving the order
  in which units were drawn. Every moved slice keeps its provenance: cash
  keeps its payment operation identity and hotel credit keeps its original
  lot, so later settlements, restorations, and clawbacks attribute exactly
  as before.

  Nothing else changes. No settlement or revaluation happens, no credit
  bonus is computed, applied credit's expiry stays paused, and no ledger
  total moves — only which active rooms hold the funding. Both participating
  groups' revisions advance exactly once.

  Like every partner operation, transfers run inside the caller's
  `Repo.transaction` so domain changes commit together with the durable
  idempotency record.
  """

  alias GroupStay.Fundings
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Repo
  alias GroupStay.Transfers.Participation

  import Ecto.Query

  @type error :: {:error, atom(), map()}

  @doc """
  Moves `amount_cents` of held funding from one group to another.

  Validation order: source existence, then destination existence (each
  missing group rejects with `group_not_found` naming it), then the source's
  expected revision, then the destination's, then the transfer rules —
  `invalid_transfer`, active state per group, `invalid_amount`,
  `transfer_exceeds_held_funding`, `transfer_exceeds_outstanding`.
  """
  def transfer_deposit(source_group_id, destination_group_id, amount_cents, opts \\ []) do
    expected_revision = Keyword.get(opts, :expected_revision)
    destination_expected_revision = Keyword.get(opts, :destination_expected_revision)

    with {:ok, source} <- load_group(source_group_id),
         {:ok, destination} <- load_group(destination_group_id),
         :ok <- check_revision(source, expected_revision),
         :ok <- check_revision(destination, destination_expected_revision),
         :ok <- ensure_distinct_same_guest(source, destination),
         :ok <- ensure_active(source),
         :ok <- ensure_active(destination),
         :ok <- validate_amount(amount_cents),
         :ok <- ensure_within_held_funding(source, amount_cents),
         :ok <- ensure_within_outstanding(destination, amount_cents) do
      move(source, destination, amount_cents)
    end
  end

  @doc """
  Whether a cash payment has ever had held funding moved by a transfer.
  """
  def participated?(payment_operation_id) do
    Repo.exists?(from(p in Participation, where: p.operation_id == ^payment_operation_id))
  end

  defp move(%Group{} = source, %Group{} = destination, amount_cents) do
    drawn = Fundings.draw_held_funding(source.id, amount_cents)
    Fundings.fill_from_drawn(destination, drawn)

    mark_cash_participants(drawn)

    revisions = Groups.bump_revisions!([source.id, destination.id])

    {:ok,
     %{
       source_group_id: source.group_id,
       destination_group_id: destination.group_id,
       amount_cents: amount_cents,
       source_outstanding_deposit_cents: Groups.outstanding_cents(source),
       destination_outstanding_deposit_cents: Groups.outstanding_cents(destination),
       source_revision: Map.fetch!(revisions, source.id),
       destination_revision: Map.fetch!(revisions, destination.id)
     }}
  end

  # Cash keeps its payment identity across the move; only cash payments have
  # statements, so only their participation is recorded.
  defp mark_cash_participants(drawn) do
    drawn
    |> Enum.map(fn {_taken, funding} -> funding end)
    |> Enum.filter(&(&1.kind == "cash" and is_binary(&1.operation_id)))
    |> Enum.map(& &1.operation_id)
    |> Enum.uniq()
    |> Enum.each(&mark_participant/1)
  end

  defp mark_participant(operation_id) do
    %Participation{}
    |> Participation.changeset(%{operation_id: operation_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :operation_id)

    :ok
  end

  defp load_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found, %{group_id: group_id}}
      group -> {:ok, group}
    end
  end

  defp check_revision(_group, nil), do: :ok

  defp check_revision(group, expected_revision) do
    if expected_revision == group.revision,
      do: :ok,
      else:
        {:error, :stale_revision,
         %{
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
  end

  defp ensure_distinct_same_guest(source, destination) do
    if source.group_id == destination.group_id or source.guest_id != destination.guest_id,
      do: {:error, :invalid_transfer, %{}},
      else: :ok
  end

  defp ensure_active(group),
    do:
      if(Group.active?(group),
        do: :ok,
        else: {:error, :group_not_active, %{group_id: group.group_id}}
      )

  defp validate_amount(amount),
    do: if(usable_amount?(amount), do: :ok, else: {:error, :invalid_amount, %{}})

  # Held funding is cash plus hotel credit currently allocated to the
  # group's active rooms; settled fundings no longer exist as rows.
  defp ensure_within_held_funding(source, amount_cents) do
    held =
      Fundings.group_held_cents(source.id, "cash") +
        Fundings.group_held_cents(source.id, "credit")

    if amount_cents <= held,
      do: :ok,
      else: {:error, :transfer_exceeds_held_funding, %{}}
  end

  defp ensure_within_outstanding(destination, amount_cents) do
    if amount_cents <= Groups.outstanding_cents(destination),
      do: :ok,
      else: {:error, :transfer_exceeds_outstanding, %{}}
  end

  defp usable_amount?(amount), do: is_integer(amount) and amount > 0
end
