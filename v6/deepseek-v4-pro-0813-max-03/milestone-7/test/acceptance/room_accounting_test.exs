defmodule GroupStayWeb.RoomAccountingAndPaymentsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Credit.CreditAllocation
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  import Ecto.Query

  defp json_header(conn) do
    put_req_header(conn, "content-type", "application/json")
  end

  defp submit_batch(conn, operations) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "guest_id" => "guest-1",
        "property_id" => "prop-1",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "r1", "nightly_rate_cents" => 10_000},
          %{"room_id" => "r2", "nightly_rate_cents" => 10_000}
        ]
      },
      overrides
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

  defp apply_credit(group_id, amount_cents, occurred_on, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
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

  defp cancel_rooms(group_id, room_ids, occurred_on, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_rooms",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "room_ids" => room_ids
      },
      extra
    )
  end

  defp reduce(payment_operation_id, amount_cents, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      extra
    )
  end

  defp charge_back(payment_operation_id, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => payment_operation_id
      },
      extra
    )
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

  defp seed_credit(conn, seed_group_id, seed_cancel_op) do
    submit_batch(conn, [
      open(%{"group_id" => seed_group_id, "operation_id" => "#{seed_group_id}-open"}),
      pay(seed_group_id, 10_000, "#{seed_group_id}-pay"),
      cancel(seed_group_id, "2026-11-26", seed_cancel_op, %{"refund_method" => "hotel_credit"})
    ])
  end

  describe "room-level accounting" do
    test "exposes room deposits and funds rooms in original order", %{conn: conn} do
      assert %{"results" => [_open, paid]} =
               submit_batch(conn, [open(), pay("g-1", 3_000, "p-1")])

      assert paid == %{
               "operation_id" => "p-1",
               "status" => "applied",
               "group_id" => "g-1",
               "amount_cents" => 3_000,
               "outstanding_deposit_cents" => 9_000,
               "revision" => 2
             }

      assert %{"data" => group} = read_group(conn, "g-1")

      assert group["rooms"] == [
               %{
                 "room_id" => "r1",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 3_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "r2",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]

      assert %{
               "lodging_total_cents" => 60_000,
               "deposit_due_cents" => 12_000,
               "deposit_paid_cents" => 3_000,
               "cash_paid_cents" => 3_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 9_000
             } = group

      submit_batch(conn, [pay("g-1", 9_000, "p-2")])

      assert %{"data" => %{"rooms" => rooms, "outstanding_deposit_cents" => 0}} =
               read_group(conn, "g-1")

      assert rooms == [
               %{
                 "room_id" => "r1",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 6_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "r2",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 6_000,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "credit continues filling the shared room cursor after cash", %{conn: conn} do
      seed_credit(conn, "seed", "seed-cancel")

      submit_batch(conn, [
        open(%{"group_id" => "g-2", "operation_id" => "g2-open"}),
        pay("g-2", 3_000, "g2-pay"),
        apply_credit("g-2", 4_000, "2026-11-20", "g2-apply")
      ])

      assert %{"data" => %{"rooms" => rooms}} = read_group(conn, "g-2")

      assert rooms == [
               %{
                 "room_id" => "r1",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 3_000,
                 "credit_paid_cents" => 3_000
               },
               %{
                 "room_id" => "r2",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 1_000
               }
             ]
    end

    test "brings pre-durable funding forward as one senior block", %{conn: conn} do
      submit_batch(conn, [open(%{"group_id" => "legacy-g"})])

      lot =
        Repo.insert!(%CreditLot{
          guest_id: "guest-1",
          source_operation_id: "legacy-cancel",
          remaining_cents: 3_000,
          expires_on: ~D[2027-11-26]
        })

      [group] = Repo.all(from g in Group, where: g.group_id == "legacy-g")

      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        set: [deposit_paid_cents: 5_000, credit_paid_cents: 2_000]
      )

      Repo.insert!(%CreditAllocation{group_id: group.id, lot_id: lot.id, amount_cents: 2_000})

      assert %{
               "data" => %{
                 "rooms" => rooms,
                 "cash_paid_cents" => 5_000,
                 "credit_paid_cents" => 2_000
               }
             } = read_group(conn, "legacy-g")

      assert rooms == [
               %{
                 "room_id" => "r1",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 5_000,
                 "credit_paid_cents" => 1_000
               },
               %{
                 "room_id" => "r2",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 1_000
               }
             ]

      # Reading again is a no-op and balances stay put.
      assert %{"data" => %{"credit_paid_cents" => 2_000}} = read_group(conn, "legacy-g")
      assert Repo.get!(CreditLot, lot.id).remaining_cents == 3_000
      assert Repo.aggregate(CreditAllocation, :count, :id) == 0

      # Ledger agrees with the brought-forward funding.
      assert %{"data" => %{"cash_held_cents" => 5_000, "credit_liability_cents" => 5_000}} =
               ledger(conn)
    end
  end

  describe "cancel_rooms" do
    test "settles only the selected rooms and keeps everything else unchanged", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 12_000, "p-1")])

      assert %{"results" => [cancelled]} =
               submit_batch(conn, [cancel_rooms("g-1", ["r2"], "2026-11-26", "cr-1")])

      assert cancelled == %{
               "operation_id" => "cr-1",
               "status" => "applied",
               "group_id" => "g-1",
               "cancelled_room_ids" => ["r2"],
               "refunded_cents" => 6_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{"data" => group} = read_group(conn, "g-1")
      assert group["status"] == "active"
      assert group["lodging_total_cents"] == 30_000
      assert group["deposit_due_cents"] == 6_000
      assert group["deposit_paid_cents"] == 6_000
      assert group["outstanding_deposit_cents"] == 0

      assert group["rooms"] == [
               %{
                 "room_id" => "r1",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 6_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "r2",
                 "nightly_rate_cents" => 10_000,
                 "status" => "cancelled",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]

      assert %{"data" => %{"cash_held_cents" => 6_000, "cash_refunded_cents" => 6_000}} =
               ledger(conn)

      # The payment statement attributes the settlement to the payment.
      assert json_response(read_payment(conn, "p-1"), 200) == %{
               "data" => %{
                 "payment_operation_id" => "p-1",
                 "original_group_id" => "g-1",
                 "recorded_cents" => 12_000,
                 "held_cents" => 6_000,
                 "refunded_cents" => 6_000,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
    end

    test "returns cancelled room ids in the group's original order", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 12_000, "p-1")])

      assert %{"results" => [cancelled]} =
               submit_batch(conn, [
                 cancel_rooms("g-1", ["r2", "r1"], "2026-11-26", "cr-1")
               ])

      assert cancelled["cancelled_room_ids"] == ["r1", "r2"]

      assert %{"data" => %{"status" => "cancelled", "deposit_due_cents" => 0}} =
               read_group(conn, "g-1")
    end

    test "computes one hotel-credit bonus on the selected rooms' combined cash", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 10_000, "p-1"), pay("g-1", 2_000, "p-2")])

      assert %{"results" => [cancelled]} =
               submit_batch(conn, [
                 cancel_rooms("g-1", ["r1", "r2"], "2026-11-26", "cr-1", %{
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert cancelled == %{
               "operation_id" => "cr-1",
               "status" => "applied",
               "group_id" => "g-1",
               "cancelled_room_ids" => ["r1", "r2"],
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 13_200,
               "revision" => 4
             }

      assert %{"data" => %{"lots" => [lot]}} = guest_credit(conn)

      assert lot == %{
               "source_operation_id" => "cr-1",
               "remaining_cents" => 13_200,
               "expires_on" => "2027-11-26"
             }

      assert %{"data" => %{"cash_converted_to_credit_cents" => 12_000}} = ledger(conn)
    end

    test "rejects unusable room lists with invalid_rooms", %{conn: conn} do
      submit_batch(conn, [
        open(),
        pay("g-1", 6_000, "p-1"),
        cancel_rooms("g-1", ["r1"], "2026-11-26", "cr-1")
      ])

      for {room_ids, index} <-
            Enum.with_index([
              ["missing"],
              [],
              ["r1"],
              ["r1", "r1"],
              [123]
            ]) do
        assert %{"results" => [rejected]} =
                 submit_batch(conn, [
                   cancel_rooms("g-1", room_ids, "2026-11-26", "cr-invalid-#{index}")
                 ])

        assert rejected["code"] == "invalid_rooms"
      end

      assert %{"data" => %{"revision" => 3, "status" => "active"}} = read_group(conn, "g-1")
    end

    test "rejects an inactive group", %{conn: conn} do
      submit_batch(conn, [open(), cancel("g-1", "2026-11-26", "c-1")])

      assert %{"results" => [rejected]} =
               submit_batch(conn, [cancel_rooms("g-1", ["r1"], "2026-11-26", "cr-1")])

      assert rejected["code"] == "group_not_active"
    end

    test "honors expected_revision and rejects stale revisions", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 5_000, "p-1")])

      stale = cancel_rooms("g-1", ["r1"], "2026-11-26", "cr-1", %{"expected_revision" => 9})

      assert %{"results" => [%{"code" => "stale_revision", "actual_revision" => 2}]} =
               submit_batch(conn, [stale])

      moved = cancel_rooms("g-1", ["r1"], "2026-11-26", "cr-2", %{"expected_revision" => 2})

      assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
               submit_batch(conn, [moved])
    end

    test "settles advance-purchase rooms non-refundably, retaining cash and consuming credit",
         %{conn: conn} do
      seed_credit(conn, "seed", "seed-cancel")

      submit_batch(conn, [
        open(%{
          "group_id" => "adv",
          "operation_id" => "adv-open",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-12",
          "rooms" => [
            %{"room_id" => "a1", "nightly_rate_cents" => 10_000},
            %{"room_id" => "a2", "nightly_rate_cents" => 10_000}
          ]
        }),
        pay("adv", 5_000, "adv-pay"),
        apply_credit("adv", 5_000, "2026-11-20", "adv-apply")
      ])

      assert %{"results" => [cancelled]} =
               submit_batch(conn, [
                 cancel_rooms("adv", ["a1"], "2026-11-26", "adv-cancel")
               ])

      assert cancelled == %{
               "operation_id" => "adv-cancel",
               "status" => "applied",
               "group_id" => "adv",
               "cancelled_room_ids" => ["a1"],
               "refunded_cents" => 0,
               "retained_cents" => 5_000,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      assert %{"data" => %{"available_cents" => 6_000, "lots" => [lot]}} = guest_credit(conn)
      assert lot["remaining_cents"] == 6_000

      assert %{"data" => %{"cash_retained_cents" => 5_000, "credit_liability_cents" => 6_000}} =
               ledger(conn)
    end

    test "restores applied credit for refundable cancels only for selected rooms", %{conn: conn} do
      seed_credit(conn, "seed", "seed-cancel")

      submit_batch(conn, [
        open(%{"group_id" => "g-2", "operation_id" => "g2-open"}),
        apply_credit("g-2", 8_000, "2026-11-20", "g2-apply"),
        cancel_rooms("g-2", ["r1"], "2026-11-25", "g2-cancel")
      ])

      assert %{"data" => %{"rooms" => [r1, r2], "credit_paid_cents" => 2_000}} =
               read_group(conn, "g-2")

      assert %{
               "room_id" => "r1",
               "status" => "cancelled",
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             } = r1

      assert %{"room_id" => "r2", "status" => "active", "credit_paid_cents" => 2_000} = r2

      # 6,000 credit returned to the original lot and available again.
      assert %{"data" => %{"available_cents" => 9_000}} = guest_credit(conn)
    end
  end

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the outstanding deposit",
         %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 10_000, "p-1")])

      assert %{"results" => [reduced]} =
               submit_batch(conn, [reduce("p-1", 2_500, "r-1")])

      assert reduced == %{
               "operation_id" => "r-1",
               "status" => "applied",
               "payment_operation_id" => "p-1",
               "group_id" => "g-1",
               "amount_cents" => 2_500,
               "outstanding_deposit_cents" => 4_500,
               "revision" => 3
             }

      assert %{"data" => %{"rooms" => rooms, "outstanding_deposit_cents" => 4_500}} =
               read_group(conn, "g-1")

      assert rooms == [
               %{
                 "room_id" => "r1",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 6_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "r2",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 1_500,
                 "credit_paid_cents" => 0
               }
             ]

      assert %{"data" => %{"cash_held_cents" => 7_500, "cash_reduced_cents" => 2_500}} =
               ledger(conn)
    end

    test "successive reductions compose and may consume the full remaining held cash",
         %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 10_000, "p-1")])

      submit_batch(conn, [reduce("p-1", 2_500, "r-1")])

      assert %{"results" => [reduced]} =
               submit_batch(conn, [reduce("p-1", 7_500, "r-2")])

      assert reduced["amount_cents"] == 7_500
      assert reduced["outstanding_deposit_cents"] == 12_000

      assert %{"data" => %{"deposit_paid_cents" => 0, "outstanding_deposit_cents" => 12_000}} =
               read_group(conn, "g-1")

      assert %{"data" => %{"cash_held_cents" => 0, "cash_reduced_cents" => 10_000}} =
               ledger(conn)

      # No held cash remains: another positive reduction is impossible.
      assert %{"results" => [%{"code" => "payment_not_reducible"}]} =
               submit_batch(conn, [reduce("p-1", 100, "r-3")])
    end

    test "uses the rejection codes from the contract", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 3_000, "p-1")])

      # Unknown payment identifier.
      assert %{"results" => [%{"code" => "operation_not_found"}]} =
               submit_batch(conn, [reduce("never-seen", 100, "r-x")])

      # Not a payment operation.
      assert %{"results" => [%{"code" => "payment_not_reducible"}]} =
               submit_batch(conn, [reduce("op-1", 100, "r-x2")])

      # A rejected payment can never accept a positive reduction.
      submit_batch(conn, [pay("missing-group", 100, "p-rejected")])

      assert %{"results" => [%{"code" => "payment_not_reducible"}]} =
               submit_batch(conn, [reduce("p-rejected", 100, "r-x3")])

      # Non-positive amounts.
      for {amount, index} <- Enum.with_index([0, -5]) do
        assert %{"results" => [%{"code" => "invalid_amount"}]} =
                 submit_batch(conn, [reduce("p-1", amount, "r-x4-#{index}")])
      end

      # Amount exceeds the currently held cash.
      assert %{"results" => [%{"code" => "reduction_exceeds_held_cash"}]} =
               submit_batch(conn, [reduce("p-1", 3_001, "r-x5")])

      assert %{"results" => [%{"code" => "stale_revision"}]} =
               submit_batch(conn, [
                 reduce("p-1", 100, "r-x6", %{"expected_revision" => 42})
               ])

      # The group was left untouched by all of the rejections.
      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 3_000}} =
               read_group(conn, "g-1")
    end

    test "replays durably without reapplying", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 10_000, "p-1")])

      reduction = reduce("p-1", 2_000, "r-1")

      first = submit_batch(conn, [reduction])
      second = submit_batch(conn, [reduction])

      assert first == second

      assert %{"data" => %{"cash_held_cents" => 8_000, "cash_reduced_cents" => 2_000}} =
               ledger(conn)
    end

    test "a partially reduced payment can still be charged back for the remainder", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 10_000, "p-1"), reduce("p-1", 4_000, "r-1")])

      assert %{"results" => [charged]} =
               submit_batch(conn, [charge_back("p-1", "cb-1")])

      assert charged["charged_back_cents"] == 6_000
      assert charged["outstanding_deposit_cents"] == 12_000

      assert json_response(read_payment(conn, "p-1"), 200) == %{
               "data" => %{
                 "payment_operation_id" => "p-1",
                 "original_group_id" => "g-1",
                 "recorded_cents" => 10_000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 4_000,
                 "charged_back_cents" => 6_000
               }
             }
    end
  end

  describe "charge_back_payment" do
    test "reverses all held cash and reopens the outstanding deposit", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 10_000, "p-1")])

      assert %{"results" => [charged]} =
               submit_batch(conn, [charge_back("p-1", "cb-1")])

      assert charged == %{
               "operation_id" => "cb-1",
               "status" => "applied",
               "payment_operation_id" => "p-1",
               "group_id" => "g-1",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 12_000,
               "revision" => 3
             }

      assert %{"data" => %{"deposit_paid_cents" => 0, "outstanding_deposit_cents" => 12_000}} =
               read_group(conn, "g-1")

      assert %{"data" => %{"cash_held_cents" => 0, "cash_charged_back_cents" => 10_000}} =
               ledger(conn)

      # A second chargeback is impossible.
      assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
               submit_batch(conn, [charge_back("p-1", "cb-2")])
    end

    test "works for payments whose group is cancelled", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 5_000, "p-1"), cancel("g-1", "2026-11-26", "c-1")])

      assert %{"results" => [charged]} =
               submit_batch(conn, [charge_back("p-1", "cb-1")])

      assert charged["charged_back_cents"] == 5_000
      assert charged["outstanding_deposit_cents"] == 0
      assert charged["revision"] == 4

      assert %{"data" => %{"cash_refunded_cents" => 0, "cash_charged_back_cents" => 5_000}} =
               ledger(conn)

      assert %{"data" => %{"status" => "cancelled", "revision" => 4}} = read_group(conn, "g-1")
    end

    test "revokes the entitlement of a converted payment on a cancelled group", %{conn: conn} do
      submit_batch(conn, [
        open(),
        pay("g-1", 10_000, "p-1"),
        cancel("g-1", "2026-11-26", "c-1", %{"refund_method" => "hotel_credit"})
      ])

      assert %{"data" => %{"available_cents" => 11_000}} = guest_credit(conn)

      assert %{"results" => [charged]} =
               submit_batch(conn, [charge_back("p-1", "cb-1")])

      assert charged["charged_back_cents"] == 10_000
      assert charged["outstanding_deposit_cents"] == 0

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = guest_credit(conn)

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 10_000,
                 "credit_liability_cents" => 0
               }
             } = ledger(conn)

      assert json_response(read_payment(conn, "p-1"), 200)["data"] == %{
               "payment_operation_id" => "p-1",
               "original_group_id" => "g-1",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 10_000
             }
    end

    test "uses the rejection codes from the contract", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 3_000, "p-1")])

      assert %{"results" => [%{"code" => "operation_not_found"}]} =
               submit_batch(conn, [charge_back("never-seen", "cb-x")])

      assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
               submit_batch(conn, [charge_back("op-1", "cb-x2")])

      submit_batch(conn, [pay("missing-group", 100, "p-rejected")])

      assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
               submit_batch(conn, [charge_back("p-rejected", "cb-x3")])

      # Fully reduced payments cannot be charged back.
      submit_batch(conn, [reduce("p-1", 3_000, "r-full")])

      assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
               submit_batch(conn, [charge_back("p-1", "cb-x4")])

      assert %{"results" => [%{"code" => "stale_revision"}]} =
               submit_batch(conn, [
                 charge_back("p-1", "cb-x5", %{"expected_revision" => 42})
               ])
    end

    test "revokes credit entitlement in the funding order used by room accounting",
         %{conn: conn} do
      submit_batch(conn, [
        open(%{"group_id" => "a", "operation_id" => "a-open"}),
        pay("a", 10_000, "p-a1"),
        pay("a", 2_000, "p-a2"),
        cancel_rooms("a", ["r1", "r2"], "2026-11-26", "cr-a", %{"refund_method" => "hotel_credit"}),
        open(%{"group_id" => "b", "operation_id" => "b-open"}),
        apply_credit("b", 12_000, "2026-11-20", "b-apply")
      ])

      assert %{"data" => %{"available_cents" => 1_200}} = guest_credit(conn)

      assert %{"results" => [charged]} =
               submit_batch(conn, [charge_back("p-a2", "cb-a")])

      assert charged == %{
               "operation_id" => "cb-a",
               "status" => "applied",
               "payment_operation_id" => "p-a2",
               "group_id" => "a",
               "charged_back_cents" => 2_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 5
             }

      # p-a2's entitlement is B(12000) - B(10000) = 13200 - 11000 = 2200.
      # Only 1200 remained; the rest becomes an unrecovered clawback covered
      # by 12000 of the lot still applied to active group b.
      assert %{"data" => %{"available_cents" => 0}} = guest_credit(conn)

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 10_000,
                 "cash_charged_back_cents" => 2_000,
                 "credit_liability_cents" => 12_000,
                 "credit_shortfall_cents" => 1_000
               }
             } = ledger(conn)

      assert %{"data" => %{"revision" => 5}} = read_group(conn, "a")

      assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 12_000}} =
               read_group(conn, "b")

      # Non-refundably settling group b's applied credit clears the shortfall.
      submit_batch(conn, [
        %{
          "operation_id" => "b-move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-11-19",
          "group_id" => "b",
          "new_arrival_on" => "2026-12-01"
        },
        cancel("b", "2026-12-10", "b-cancel")
      ])

      assert %{"data" => %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0}} =
               ledger(conn)
    end

    test "restored credit is absorbed by shortfall before becoming available", %{conn: conn} do
      submit_batch(conn, [
        open(%{"group_id" => "a", "operation_id" => "a-open"}),
        pay("a", 10_000, "p-a1"),
        pay("a", 2_000, "p-a2"),
        cancel_rooms("a", ["r1", "r2"], "2026-11-26", "cr-a", %{"refund_method" => "hotel_credit"}),
        open(%{"group_id" => "b", "operation_id" => "b-open"}),
        apply_credit("b", 12_000, "2026-11-20", "b-apply"),
        charge_back("p-a2", "cb-a")
      ])

      # Refundable cancellation of b returns its 12,000 applied credit to the lot.
      assert %{"results" => [cancelled]} =
               submit_batch(conn, [cancel("b", "2026-11-25", "b-cancel")])

      assert cancelled["refunded_cents"] == 0

      # 1,000 extinguishes the unrecovered clawback; only 11,000 becomes available.
      assert %{"data" => %{"available_cents" => 11_000}} = guest_credit(conn)

      assert %{
               "data" => %{"credit_liability_cents" => 11_000, "credit_shortfall_cents" => 0}
             } = ledger(conn)
    end

    test "replays durably without reapplying", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 4_000, "p-1")])

      op = charge_back("p-1", "cb-1")
      first = submit_batch(conn, [op])
      second = submit_batch(conn, [op])

      assert first == second
      assert %{"data" => %{"cash_charged_back_cents" => 4_000}} = ledger(conn)
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns the current disposition of one applied payment", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 5_000, "pay-17")])

      conn_response = read_payment(conn, "pay-17")

      assert json_response(conn_response, 200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-17",
                 "original_group_id" => "g-1",
                 "recorded_cents" => 5_000,
                 "held_cents" => 5_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }

      submit_batch(conn, [reduce("pay-17", 1_000, "r-1")])

      assert json_response(read_payment(conn, "pay-17"), 200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-17",
                 "original_group_id" => "g-1",
                 "recorded_cents" => 5_000,
                 "held_cents" => 4_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 1_000,
                 "charged_back_cents" => 0
               }
             }
    end

    test "returns operation_not_found for an unknown identifier", %{conn: conn} do
      conn_response = read_payment(conn, "never-seen")

      assert conn_response.status == 404
      assert json_response(conn_response, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns payment_not_reconcilable for non-payment records", %{conn: conn} do
      submit_batch(conn, [open()])
      submit_batch(conn, [pay("missing-group", 100, "p-rejected")])

      for target <- ["op-1", "p-rejected"] do
        conn_response = read_payment(conn, target)
        assert conn_response.status == 422

        assert json_response(conn_response, 422) ==
                 %{"error" => %{"code" => "payment_not_reconcilable"}}
      end
    end

    test "reading a statement never changes state", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 5_000, "pay-17")])

      before = json_response(read_payment(conn, "pay-17"), 200)
      assert json_response(read_payment(conn, "pay-17"), 200) == before

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 5_000}} =
               read_group(conn, "g-1")
    end

    test "agrees with the group, room and ledger views after a chargeback", %{conn: conn} do
      submit_batch(conn, [open(), pay("g-1", 3_000, "p-1"), cancel("g-1", "2026-11-26", "c-1")])

      submit_batch(conn, [charge_back("p-1", "cb-1")])

      assert json_response(read_payment(conn, "p-1"), 200) == %{
               "data" => %{
                 "payment_operation_id" => "p-1",
                 "original_group_id" => "g-1",
                 "recorded_cents" => 3_000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 3_000
               }
             }

      assert %{"data" => %{"cash_charged_back_cents" => 3_000, "cash_held_cents" => 0}} =
               ledger(conn)
    end
  end
end
