defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  defp json_header(conn) do
    put_req_header(conn, "content-type", "application/json")
  end

  defp submit_batch(conn, operations) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open(group_id, guest_id \\ "guest-1", extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{group_id}-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "prop-1",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "r1", "nightly_rate_cents" => 10_000},
          %{"room_id" => "r2", "nightly_rate_cents" => 10_000}
        ]
      },
      extra
    )
  end

  defp pay(group_id, amount_cents, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer(source, destination, amount_cents, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount_cents
      },
      extra
    )
  end

  defp cancel(group_id, occurred_on, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extra
    )
  end

  defp apply_credit(group_id, amount_cents, occurred_on, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce(payment_operation_id, amount_cents, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      extra
    )
  end

  defp charge_back(payment_operation_id, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-06",
      "payment_operation_id" => payment_operation_id
    }
  end

  defp read_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp read_payment(conn, payment_op_id) do
    conn
    |> get("/api/v1/payments/#{payment_op_id}")
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
  end

  defp guest_credit(conn, guest_id \\ "guest-1") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
  end

  defp open_pair(conn) do
    submit_batch(conn, [open("g-1"), open("g-2")])
  end

  defp seed_credit(conn, seed_group_id \\ "seed") do
    submit_batch(conn, [
      open(seed_group_id),
      pay(seed_group_id, 5_000, "#{seed_group_id}-pay"),
      cancel(seed_group_id, "2026-11-26", "#{seed_group_id}-cancel", %{
        "refund_method" => "hotel_credit"
      })
    ])
  end

  describe "transfer_deposit" do
    test "moves held cash between two active groups of the same guest", %{conn: conn} do
      open_pair(conn)

      assert %{"results" => [_paid, transferred]} =
               submit_batch(conn, [
                 pay("g-1", 12_000, "p-1"),
                 transfer("g-1", "g-2", 6_000, "t-1")
               ])

      assert transferred == %{
               "operation_id" => "t-1",
               "status" => "applied",
               "source_group_id" => "g-1",
               "destination_group_id" => "g-2",
               "amount_cents" => 6_000,
               "source_outstanding_deposit_cents" => 6_000,
               "destination_outstanding_deposit_cents" => 6_000,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      assert %{"data" => source} = read_group(conn, "g-1")
      assert source["revision"] == 3
      assert source["deposit_paid_cents"] == 6_000
      assert source["outstanding_deposit_cents"] == 6_000

      assert [
               %{"room_id" => "r1", "cash_paid_cents" => 6_000},
               %{"room_id" => "r2", "cash_paid_cents" => 0}
             ] = source["rooms"]

      assert %{"data" => destination} = read_group(conn, "g-2")
      assert destination["revision"] == 2
      assert destination["deposit_paid_cents"] == 6_000
      assert destination["outstanding_deposit_cents"] == 6_000

      assert [
               %{"room_id" => "r1", "cash_paid_cents" => 6_000},
               %{"room_id" => "r2", "cash_paid_cents" => 0}
             ] = destination["rooms"]

      # A transfer changes no ledger total.
      assert %{"data" => %{"cash_held_cents" => 12_000}} = ledger(conn)

      # Both groups' revisions continue to move with later operations.
      assert %{"results" => [%{"status" => "applied", "source_revision" => 4}]} =
               submit_batch(conn, [transfer("g-1", "g-2", 100, "t-2")])
    end

    test "draws in reverse allocation order, keeping payment provenance", %{conn: conn} do
      open_pair(conn)

      submit_batch(conn, [
        pay("g-1", 8_000, "p-1"),
        pay("g-1", 4_000, "p-2"),
        transfer("g-1", "g-2", 3_000, "t-1")
      ])

      # p-2 funded rooms last, so the transfer takes from p-2 first.
      assert json_response(read_payment(conn, "p-1"), 200) == %{
               "data" => %{
                 "payment_operation_id" => "p-1",
                 "original_group_id" => "g-1",
                 "recorded_cents" => 8_000,
                 "held_cents" => 8_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }

      assert json_response(read_payment(conn, "p-2"), 200) == %{
               "data" => %{
                 "payment_operation_id" => "p-2",
                 "original_group_id" => "g-1",
                 "recorded_cents" => 4_000,
                 "held_cents" => 4_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0,
                 "held_by_group" => [
                   %{"group_id" => "g-1", "amount_cents" => 1_000},
                   %{"group_id" => "g-2", "amount_cents" => 3_000}
                 ]
               }
             }

      assert %{"data" => %{"rooms" => [r1, r2]}} = read_group(conn, "g-1")
      assert r1["cash_paid_cents"] == 6_000
      assert r2["cash_paid_cents"] == 3_000

      assert %{"data" => %{"rooms" => [dr1, dr2]}} = read_group(conn, "g-2")
      assert dr1["cash_paid_cents"] == 3_000
      assert dr2["cash_paid_cents"] == 0
    end

    test "fills the destination's rooms in their original order", %{conn: conn} do
      open_pair(conn)

      submit_batch(conn, [
        pay("g-1", 12_000, "p-1"),
        transfer("g-1", "g-2", 7_000, "t-1")
      ])

      assert %{"data" => %{"rooms" => [r1, r2]}} = read_group(conn, "g-1")
      assert r1["cash_paid_cents"] == 5_000
      assert r2["cash_paid_cents"] == 0

      assert %{"data" => %{"rooms" => [dr1, dr2]}} = read_group(conn, "g-2")
      assert dr1["cash_paid_cents"] == 6_000
      assert dr2["cash_paid_cents"] == 1_000
      assert Map.get(dr1, "credit_paid_cents") == 0
    end

    test "returns the stored result on retry without moving funding again", %{conn: conn} do
      open_pair(conn)
      submit_batch(conn, [pay("g-1", 12_000, "p-1")])

      op = transfer("g-1", "g-2", 6_000, "t-1")

      first = submit_batch(conn, [op])
      submit_batch(conn, [pay("g-1", 1_000, "p-late")])
      second = submit_batch(conn, [op])

      assert first == second

      assert %{"data" => %{"deposit_paid_cents" => 7_000, "revision" => 4}} =
               read_group(conn, "g-1")
    end

    test "replays a repeated operation inside one batch once", %{conn: conn} do
      open_pair(conn)
      submit_batch(conn, [pay("g-1", 12_000, "p-1")])

      op = transfer("g-1", "g-2", 6_000, "t-1")

      assert %{"results" => [first, second]} = submit_batch(conn, [op, op])
      assert first == second

      assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 6_000}} =
               read_group(conn, "g-1")

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 6_000}} =
               read_group(conn, "g-2")
    end

    test "draws across funding kinds in reverse allocation order", %{conn: conn} do
      seed_credit(conn)
      open_pair(conn)

      submit_batch(conn, [
        pay("g-1", 6_000, "p-1"),
        apply_credit("g-1", 5_500, "2026-11-20", "apply-1"),
        transfer("g-1", "g-2", 9_000, "t-1")
      ])

      # The credit was allocated after the cash, so it is drawn first.
      assert %{
               "data" => %{
                 "rooms" => [r1, r2],
                 "deposit_paid_cents" => 2_500,
                 "credit_paid_cents" => 0
               }
             } =
               read_group(conn, "g-1")

      assert r1["cash_paid_cents"] == 2_500
      assert r2["cash_paid_cents"] == 0

      assert %{
               "data" => %{
                 "rooms" => [dr1, dr2],
                 "deposit_paid_cents" => 3_500,
                 "credit_paid_cents" => 5_500
               }
             } =
               read_group(conn, "g-2")

      assert dr1["cash_paid_cents"] == 500
      assert dr1["credit_paid_cents"] == 5_500
      assert dr2["cash_paid_cents"] == 3_000
      assert dr2["credit_paid_cents"] == 0

      # Ledger totals are untouched by the transfer.
      assert %{"data" => %{"cash_held_cents" => 6_000, "credit_liability_cents" => 5_500}} =
               ledger(conn)
    end

    test "transfers of legacy funding stay moved when groups are read again", %{conn: conn} do
      open_pair(conn)

      [group] = Repo.all(from g in Group, where: g.group_id == "g-1")

      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        set: [deposit_paid_cents: 5_000]
      )

      # Reading materializes the unattributed senior block.
      assert %{"data" => %{"rooms" => [r1, _r2], "deposit_paid_cents" => 5_000}} =
               read_group(conn, "g-1")

      assert r1["cash_paid_cents"] == 5_000

      assert %{"results" => [transferred]} =
               submit_batch(conn, [transfer("g-1", "g-2", 2_000, "t-1")])

      assert transferred["status"] == "applied"

      assert %{"data" => %{"deposit_paid_cents" => 3_000}} = read_group(conn, "g-1")
      assert %{"data" => %{"deposit_paid_cents" => 2_000}} = read_group(conn, "g-2")
      assert %{"data" => %{"cash_held_cents" => 5_000}} = ledger(conn)

      # Repeated reads never re-materialize the moved-out block.
      assert %{"data" => %{"deposit_paid_cents" => 3_000}} = read_group(conn, "g-1")
      assert Repo.aggregate(from(a in GroupStay.Accounting.RoomAllocation), :count, :id) == 2
    end

    test "uses the rejection codes from the contract", %{conn: conn} do
      open_pair(conn)
      submit_batch(conn, [pay("g-1", 6_000, "p-1")])

      # Same group.
      assert %{"results" => [%{"code" => "invalid_transfer"}]} =
               submit_batch(conn, [transfer("g-1", "g-1", 100, "x-1")])

      # Different guests.
      submit_batch(conn, [open("g-other", "guest-2")])

      assert %{"results" => [%{"code" => "invalid_transfer"}]} =
               submit_batch(conn, [transfer("g-1", "g-other", 100, "x-2")])

      # Missing groups resolve source first, then destination.
      assert %{"results" => [result]} =
               submit_batch(conn, [transfer("missing-src", "missing-dst", 100, "x-3")])

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "missing-src"

      assert %{"results" => [result]} =
               submit_batch(conn, [transfer("g-1", "missing-dst", 100, "x-4")])

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "missing-dst"

      # Non-positive amounts.
      for {amount, index} <- Enum.with_index([0, -5]) do
        assert %{"results" => [%{"code" => "invalid_amount"}]} =
                 submit_batch(conn, [transfer("g-1", "g-2", amount, "x-5-#{index}")])
      end

      # More than the source holds.
      assert %{"results" => [%{"code" => "transfer_exceeds_held_funding"}]} =
               submit_batch(conn, [transfer("g-1", "g-2", 6_001, "x-6")])

      # More than the destination needs.
      submit_batch(conn, [pay("g-2", 12_000, "p-2")])

      assert %{"results" => [%{"code" => "transfer_exceeds_outstanding"}]} =
               submit_batch(conn, [transfer("g-1", "g-2", 100, "x-7")])

      # Inactive destination: the destination's group id is reported.
      submit_batch(conn, [cancel("g-2", "2026-11-26", "c-2")])

      assert %{"results" => [result]} =
               submit_batch(conn, [transfer("g-1", "g-2", 100, "x-8")])

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "g-2"

      # Inactive source: the source's group id is reported.
      submit_batch(conn, [cancel("g-1", "2026-11-26", "c-1")])

      assert %{"results" => [result]} =
               submit_batch(conn, [transfer("g-1", "g-2", 100, "x-9")])

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "g-1"

      # None of the rejections transferred any funding.
      assert %{"data" => %{"revision" => 3, "status" => "cancelled"}} = read_group(conn, "g-1")
      assert %{"data" => %{"revision" => 3, "status" => "cancelled"}} = read_group(conn, "g-2")
    end

    test "checks the source revision and then the destination revision", %{conn: conn} do
      open_pair(conn)
      submit_batch(conn, [pay("g-1", 6_000, "p-1")])

      # Both stale: the source is reported.
      assert %{"results" => [result]} =
               submit_batch(conn, [
                 transfer("g-1", "g-2", 100, "x-1", %{
                   "expected_revision" => 9,
                   "destination_expected_revision" => 9
                 })
               ])

      assert result == %{
               "operation_id" => "x-1",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "g-1",
               "expected_revision" => 9,
               "actual_revision" => 2
             }

      # Only the destination stale: destination is reported.
      assert %{"results" => [result]} =
               submit_batch(conn, [
                 transfer("g-1", "g-2", 100, "x-2", %{
                   "expected_revision" => 2,
                   "destination_expected_revision" => 9
                 })
               ])

      assert result == %{
               "operation_id" => "x-2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "g-2",
               "expected_revision" => 9,
               "actual_revision" => 1
             }

      # Correct guards apply.
      assert %{"results" => [%{"status" => "applied", "source_revision" => 3}]} =
               submit_batch(conn, [
                 transfer("g-1", "g-2", 100, "x-3", %{
                   "expected_revision" => 2,
                   "destination_expected_revision" => 1
                 })
               ])

      # Now the destination guard is stale.
      assert %{"results" => [%{"code" => "stale_revision", "group_id" => "g-2"}]} =
               submit_batch(conn, [
                 transfer("g-1", "g-2", 100, "x-4", %{
                   "expected_revision" => 3,
                   "destination_expected_revision" => 1
                 })
               ])
    end
  end

  describe "transferred hotel credit" do
    test "keeps its lot and restores to it without a second bonus", %{conn: conn} do
      seed_credit(conn)
      open_pair(conn)

      submit_batch(conn, [
        apply_credit("g-1", 5_500, "2026-11-20", "apply-1"),
        transfer("g-1", "g-2", 2_500, "t-1")
      ])

      # The lot stays fully applied while both groups hold it.
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = guest_credit(conn)

      assert %{"data" => %{"rooms" => rooms1}} = read_group(conn, "g-1")
      assert Enum.at(rooms1, 0)["credit_paid_cents"] == 3_000

      assert %{"data" => %{"rooms" => rooms2}} = read_group(conn, "g-2")
      assert Enum.at(rooms2, 0)["credit_paid_cents"] == 2_500

      # Refundable cancellation of the destination restores to the original lot.
      assert %{"results" => [%{"status" => "applied", "refunded_cents" => 0}]} =
               submit_batch(conn, [cancel("g-2", "2026-11-18", "c-2")])

      assert %{"data" => %{"available_cents" => 2_500, "lots" => [lot]}} = guest_credit(conn)

      assert lot == %{
               "source_operation_id" => "seed-cancel",
               "remaining_cents" => 2_500,
               "expires_on" => "2027-11-26"
             }

      # Liability is unchanged: the credit simply moved between holdings.
      assert %{"data" => %{"credit_liability_cents" => 5_500}} = ledger(conn)

      # Cancelling the source group completes the restoration of the same lot.
      submit_batch(conn, [cancel("g-1", "2026-11-18", "c-1")])

      assert %{"data" => %{"available_cents" => 5_500, "lots" => [lot]}} = guest_credit(conn)
      assert lot["source_operation_id"] == "seed-cancel"
      assert lot["expires_on"] == "2027-11-26"
    end

    test "does not resume or extend the expiry of applied credit", %{conn: conn} do
      submit_batch(conn, [
        open("late", "guest-1", %{
          "arrival_on" => "2027-12-20",
          "departure_on" => "2027-12-23"
        })
      ])

      seed_credit(conn)

      submit_batch(conn, [
        open("g-1"),
        open("g-2", "guest-1", %{"arrival_on" => "2027-12-20", "departure_on" => "2027-12-23"}),
        apply_credit("g-1", 5_500, "2026-11-20", "apply-1"),
        transfer("g-1", "g-2", 2_500, "t-1")
      ])

      # Cancellation is refundable and occurs after the lot's original expiry.
      submit_batch(conn, [cancel("g-2", "2027-12-01", "c-2")])

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = guest_credit(conn)

      assert %{"data" => %{"credit_liability_cents" => 3_000}} = ledger(conn)
    end
  end

  describe "transferred cash and later settlement" do
    test "settles under the destination group's cancellation policy", %{conn: conn} do
      submit_batch(conn, [
        open("g-1"),
        open("adv", "guest-1", %{
          "operation_id" => "adv-open",
          "rate_plan" => "advance_purchase",
          "rooms" => [
            %{"room_id" => "a1", "nightly_rate_cents" => 10_000},
            %{"room_id" => "a2", "nightly_rate_cents" => 10_000}
          ]
        }),
        pay("g-1", 12_000, "p-1"),
        transfer("g-1", "adv", 6_000, "t-1")
      ])

      # Advance-purchase rooms are always non-refundable.
      assert %{"results" => [cancelled]} =
               submit_batch(conn, [cancel("adv", "2026-11-26", "c-1")])

      assert cancelled == %{
               "operation_id" => "c-1",
               "status" => "applied",
               "group_id" => "adv",
               "refunded_cents" => 0,
               "retained_cents" => 6_000,
               "revision" => 3
             }

      assert %{"data" => %{"cash_held_cents" => 6_000, "cash_retained_cents" => 6_000}} =
               ledger(conn)

      assert json_response(read_payment(conn, "p-1"), 200) == %{
               "data" => %{
                 "payment_operation_id" => "p-1",
                 "original_group_id" => "g-1",
                 "recorded_cents" => 12_000,
                 "held_cents" => 6_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 6_000,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0,
                 "held_by_group" => [%{"group_id" => "g-1", "amount_cents" => 6_000}]
               }
             }
    end

    test "applies the bonus rule to cash settled at the destination", %{conn: conn} do
      open_pair(conn)

      submit_batch(conn, [
        pay("g-1", 1_000, "p-1"),
        transfer("g-1", "g-2", 1_000, "t-1"),
        cancel("g-2", "2026-11-26", "c-2", %{"refund_method" => "hotel_credit"})
      ])

      assert %{"data" => %{"available_cents" => 1_100, "lots" => [lot]}} = guest_credit(conn)

      assert lot == %{
               "source_operation_id" => "c-2",
               "remaining_cents" => 1_100,
               "expires_on" => "2027-11-26"
             }

      assert %{"data" => %{"cash_converted_to_credit_cents" => 1_000}} = ledger(conn)

      assert json_response(read_payment(conn, "p-1"), 200)["data"] == %{
               "payment_operation_id" => "p-1",
               "original_group_id" => "g-1",
               "recorded_cents" => 1_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 1_000,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => []
             }
    end
  end

  describe "reductions and chargebacks across groups" do
    test "a reduction removes held cash in reverse allocation order across groups", %{conn: conn} do
      open_pair(conn)

      submit_batch(conn, [
        pay("g-1", 10_000, "p-1"),
        transfer("g-1", "g-2", 4_000, "t-1")
      ])

      assert %{"results" => [reduced]} = submit_batch(conn, [reduce("p-1", 2_000, "r-1")])

      assert reduced == %{
               "operation_id" => "r-1",
               "status" => "applied",
               "payment_operation_id" => "p-1",
               "group_id" => "g-1",
               "amount_cents" => 2_000,
               "outstanding_deposit_cents" => 6_000,
               "revision" => 4
             }

      # The newest allocations live in g-2, so the reduction strikes there first.
      assert %{"data" => g1} = read_group(conn, "g-1")
      assert g1["revision"] == 4
      assert g1["deposit_paid_cents"] == 6_000

      assert %{"data" => g2} = read_group(conn, "g-2")
      assert g2["revision"] == 3
      assert g2["deposit_paid_cents"] == 2_000
      assert g2["outstanding_deposit_cents"] == 10_000

      assert json_response(read_payment(conn, "p-1"), 200)["data"] == %{
               "payment_operation_id" => "p-1",
               "original_group_id" => "g-1",
               "recorded_cents" => 10_000,
               "held_cents" => 8_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2_000,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "g-1", "amount_cents" => 6_000},
                 %{"group_id" => "g-2", "amount_cents" => 2_000}
               ]
             }

      assert %{"data" => %{"cash_held_cents" => 8_000, "cash_reduced_cents" => 2_000}} =
               ledger(conn)
    end

    test "a reduction still addresses the original payment group's revision", %{conn: conn} do
      open_pair(conn)
      submit_batch(conn, [pay("g-1", 10_000, "p-1"), transfer("g-1", "g-2", 4_000, "t-1")])

      assert %{"results" => [%{"code" => "stale_revision", "group_id" => "g-1"}]} =
               submit_batch(conn, [
                 reduce("p-1", 100, "r-1", %{"expected_revision" => 42})
               ])

      assert %{"data" => %{"revision" => 3}} = read_group(conn, "g-1")
      assert %{"data" => %{"revision" => 2}} = read_group(conn, "g-2")
    end

    test "a chargeback reclassifies cash held across every group", %{conn: conn} do
      open_pair(conn)

      submit_batch(conn, [
        pay("g-1", 10_000, "p-1"),
        transfer("g-1", "g-2", 4_000, "t-1")
      ])

      assert %{"results" => [charged]} = submit_batch(conn, [charge_back("p-1", "cb-1")])

      assert charged == %{
               "operation_id" => "cb-1",
               "status" => "applied",
               "payment_operation_id" => "p-1",
               "group_id" => "g-1",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 12_000,
               "revision" => 4
             }

      assert %{
               "data" => %{
                 "revision" => 4,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 12_000
               }
             } =
               read_group(conn, "g-1")

      assert %{
               "data" => %{
                 "revision" => 3,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 12_000
               }
             } =
               read_group(conn, "g-2")

      assert json_response(read_payment(conn, "p-1"), 200)["data"] == %{
               "payment_operation_id" => "p-1",
               "original_group_id" => "g-1",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 10_000,
               "held_by_group" => []
             }

      assert %{"data" => %{"cash_held_cents" => 0, "cash_charged_back_cents" => 10_000}} =
               ledger(conn)
    end

    test "a chargeback revokes credit converted at the destination group", %{conn: conn} do
      open_pair(conn)

      submit_batch(conn, [
        pay("g-1", 5_000, "p-1"),
        transfer("g-1", "g-2", 5_000, "t-1"),
        cancel("g-2", "2026-11-20", "c-2", %{"refund_method" => "hotel_credit"})
      ])

      assert %{"data" => %{"available_cents" => 5_500}} = guest_credit(conn)

      assert %{"results" => [charged]} = submit_batch(conn, [charge_back("p-1", "cb-1")])

      assert charged["charged_back_cents"] == 5_000
      assert charged["group_id"] == "g-1"
      assert charged["revision"] == 4

      # The entitlement created at the destination is revoked.
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = guest_credit(conn)

      assert %{
               "data" => %{
                 "cash_charged_back_cents" => 5_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = ledger(conn)

      # The destination group's state changed too, so its revision moved.
      assert %{"data" => %{"revision" => 4, "status" => "cancelled"}} = read_group(conn, "g-2")

      assert json_response(read_payment(conn, "p-1"), 200)["data"] == %{
               "payment_operation_id" => "p-1",
               "original_group_id" => "g-1",
               "recorded_cents" => 5_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 5_000,
               "held_by_group" => []
             }
    end

    test "held_by_group is ordered by group_id and omitted for untouched payments", %{
      conn: conn
    } do
      submit_batch(conn, [open("g-1"), open("g-2"), open("g-3")])

      submit_batch(conn, [
        pay("g-1", 12_000, "p-1"),
        transfer("g-1", "g-2", 3_000, "t-1"),
        transfer("g-1", "g-3", 2_000, "t-2")
      ])

      assert json_response(read_payment(conn, "p-1"), 200)["data"]["held_by_group"] == [
               %{"group_id" => "g-1", "amount_cents" => 7_000},
               %{"group_id" => "g-2", "amount_cents" => 3_000},
               %{"group_id" => "g-3", "amount_cents" => 2_000}
             ]

      # A payment that never participated keeps the earlier statement shape.
      submit_batch(conn, [pay("g-3", 1_000, "p-2")])

      statement = json_response(read_payment(conn, "p-2"), 200)["data"]
      refute Map.has_key?(statement, "held_by_group")
    end
  end
end
