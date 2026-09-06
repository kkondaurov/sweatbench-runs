defmodule GroupStay.Migrations.Request05 do
  @moduledoc """
  Data backfill for the deposit-transfers release.

  Assigns every existing cash allocation a global fill-order position so a
  payment's held cash can be removed in reverse allocation order even when
  transfers later spread it across groups. Existing allocations never span
  groups, so only the per-group order is significant and the existing `seq`
  order is preserved.
  """

  import Ecto.Query

  alias GroupStay.Groups.{CashAllocation, Room}
  alias GroupStay.Repo

  def run do
    backfill_global_seq()
    :ok
  end

  defp backfill_global_seq do
    group_by_room = Repo.all(from r in Room, select: {r.id, r.group_id}) |> Map.new()

    CashAllocation
    |> Repo.all()
    |> Enum.sort_by(fn allocation ->
      {Map.fetch!(group_by_room, allocation.room_id), allocation.seq, allocation.id}
    end)
    |> Enum.with_index()
    |> Enum.each(fn {allocation, index} ->
      Repo.update_all(
        from(a in CashAllocation, where: a.id == ^allocation.id),
        set: [global_seq: index]
      )
    end)
  end
end
