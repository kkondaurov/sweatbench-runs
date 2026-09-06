defmodule GroupStayWeb.GuestCreditReadTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  defp issue_credit(conn, overrides) do
    group_id = Map.fetch!(overrides, :group_id)

    submit(conn, [
      open_group_op(
        Map.merge(
          %{operation_id: "open-" <> group_id, group_id: group_id},
          Map.take(overrides, [:guest_id, :occurred_on, :arrival_on, :departure_on])
        )
      ),
      payment_op(%{
        operation_id: "pay-" <> group_id,
        group_id: group_id,
        amount_cents: Map.get(overrides, :amount_cents, 10_000)
      }),
      cancel_op(%{
        operation_id: Map.fetch!(overrides, :source_operation_id),
        group_id: group_id,
        occurred_on: Map.fetch!(overrides, :cancelled_on),
        refund_method: "hotel_credit"
      })
    ])
  end

  describe "GET /api/v1/guests/:guest_id/credit" do
    test "returns the guest's lots under a data key", %{conn: conn} do
      issue_credit(conn, %{
        group_id: "group-81",
        source_operation_id: "cancel-17",
        cancelled_on: "2026-11-26"
      })

      assert %{"data" => data} =
               conn
               |> get("/api/v1/guests/guest-22/credit?on=2026-11-26")
               |> json_response(200)

      assert Enum.sort(Map.keys(data)) == ["available_cents", "guest_id", "lots"]

      assert [lot] = data["lots"]
      assert Enum.sort(Map.keys(lot)) == ["expires_on", "remaining_cents", "source_operation_id"]
    end

    test "a guest with no credit reads as empty", %{conn: conn} do
      assert %{"guest_id" => "guest-none", "available_cents" => 0, "lots" => []} =
               read_credit(conn, "guest-none")
    end

    test "returns the partner identifier unchanged", %{conn: conn} do
      issue_credit(conn, %{
        group_id: "group-81",
        guest_id: "Guest 22/x",
        source_operation_id: "cancel-17",
        cancelled_on: "2026-11-26"
      })

      assert %{"guest_id" => "Guest 22/x", "available_cents" => 11_000} =
               read_credit(conn, URI.encode("Guest 22/x", &(&1 != ?/)), on: "2026-11-26")
    end

    test "omits expired lots and reports expiry as of the on date", %{conn: conn} do
      issue_credit(conn, %{
        group_id: "group-81",
        source_operation_id: "cancel-17",
        cancelled_on: "2026-11-26"
      })

      # Available through 2027-11-26; the lot expires the following day.
      assert %{"available_cents" => 11_000} = read_credit(conn, "guest-22", on: "2027-11-26")

      assert %{"available_cents" => 0, "lots" => []} =
               read_credit(conn, "guest-22", on: "2027-11-27")

      assert %{"credit_liability_cents" => 11_000} = read_ledger(conn, on: "2027-11-26")
      assert %{"credit_liability_cents" => 0} = read_ledger(conn, on: "2027-11-27")
    end

    test "orders lots by expiry, then by source operation", %{conn: conn} do
      for {group_id, source_operation_id, cancelled_on} <- [
            {"group-c", "cancel-b", "2026-11-26"},
            {"group-b", "cancel-a", "2026-11-26"},
            {"group-a", "cancel-z", "2026-11-25"}
          ] do
        issue_credit(conn, %{
          group_id: group_id,
          source_operation_id: source_operation_id,
          cancelled_on: cancelled_on
        })
      end

      assert %{"lots" => lots} = read_credit(conn, "guest-22", on: "2026-11-26")

      assert Enum.map(lots, & &1["source_operation_id"]) == ~w(cancel-z cancel-a cancel-b)
    end

    test "one guest's credit is not another's", %{conn: conn} do
      issue_credit(conn, %{
        group_id: "group-81",
        source_operation_id: "cancel-17",
        cancelled_on: "2026-11-26"
      })

      assert %{"available_cents" => 0} = read_credit(conn, "guest-99", on: "2026-11-26")
    end

    test "without on it reports expiry as of the current UTC date", %{conn: conn} do
      today = Date.utc_today()

      # A lot issued 365 days ago is available through today; one issued a day
      # earlier expired today.
      for {group_id, source_operation_id, days_ago} <- [
            {"group-live", "cancel-live", 365},
            {"group-dead", "cancel-dead", 366}
          ] do
        cancelled_on = Date.add(today, -days_ago)

        issue_credit(conn, %{
          group_id: group_id,
          source_operation_id: source_operation_id,
          occurred_on: Date.to_iso8601(Date.add(cancelled_on, -1)),
          # Far enough out to be refundable under either flexible policy version.
          arrival_on: Date.to_iso8601(Date.add(cancelled_on, 40)),
          departure_on: Date.to_iso8601(Date.add(cancelled_on, 43)),
          cancelled_on: Date.to_iso8601(cancelled_on)
        })
      end

      assert %{
               "available_cents" => 11_000,
               "lots" => [%{"source_operation_id" => "cancel-live"}]
             } = read_credit(conn, "guest-22")

      assert %{"credit_liability_cents" => 11_000} = read_ledger(conn)
    end

    test "an unusable on date is refused", %{conn: conn} do
      for value <- ["", "nonsense", "2026-13-01", "2026-11-26T00:00:00Z"] do
        assert %{"error" => %{"code" => "invalid_query"}} =
                 conn |> get("/api/v1/guests/guest-22/credit?on=#{value}") |> json_response(422),
               "expected invalid_query for #{inspect(value)}"

        assert %{"error" => %{"code" => "invalid_query"}} =
                 conn |> get("/api/v1/ledger?on=#{value}") |> json_response(422)
      end
    end
  end
end
