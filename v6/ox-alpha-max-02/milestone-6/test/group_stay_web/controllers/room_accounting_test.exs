defmodule GroupStayWeb.Controllers.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Groups.RoomCashAllocation
  alias GroupStay.Repo

  ## Builders

  defp pay(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay-" <> group_id <> "-" <> Integer.to_string(amount),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel_rooms(room_ids, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "room_ids" => room_ids
      },
      overrides
    )
  end

  defp reduce(payment_operation_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp charge_back(payment_operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-charge-back",
        "type" => "charge_back_payment",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp apply_credit(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "apply-" <> group_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-25",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  # Leaves the guest with a credit lot worth 110% of `cash`, issued on
  # `cancelled_on` under operation `op_id`.
  defp issue_lot(conn, guest_id, op_id, cancelled_on, cash) do
    arrival = cancelled_on |> Date.from_iso8601!() |> Date.add(90) |> Date.to_iso8601()

    run_batch(conn, [
      open_operation(%{
        "operation_id" => "open-src-" <> op_id,
        "group_id" => "g-src-" <> op_id,
        "guest_id" => guest_id,
        "occurred_on" => cancelled_on,
        "arrival_on" => arrival,
        "departure_on" => arrival |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601(),
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      }),
      pay("g-src-" <> op_id, cash, %{"occurred_on" => cancelled_on}),
      %{
        "operation_id" => op_id,
        "type" => "cancel_group",
        "occurred_on" => cancelled_on,
        "group_id" => "g-src-" <> op_id,
        "refund_method" => "hotel_credit"
      }
    ])
  end

  defp fetch_guest_credit(conn, guest_id) do
    assert %{"data" => data} =
             get(conn, "/api/v1/guests/#{URI.encode_www_form(guest_id)}/credit")
             |> json_response(200)

    data
  end

  defp room_view(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  defp allocations(group_id) do
    group = Repo.get_by!(GroupStay.Groups.Group, group_id: group_id)

    Repo.all(
      from a in RoomCashAllocation,
        where: a.group_id == ^group.id,
        order_by: [asc: fragment("rowid")]
    )
  end

  ## Room-level accounting

  describe "room accounting reads" do
    test "rooms expose their own amounts and group totals sum the active rooms", %{conn: conn} do
      run_batch(conn, [open_operation(), pay("group-81", 4_000)])

      group = fetch_group(conn, "group-81")

      assert group["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "lodging_cents" => 45_000,
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 4_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "lodging_cents" => 52_500,
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]

      assert %{
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 4_000,
               "cash_paid_cents" => 4_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 15_500
             } = group
    end

    test "cash fills one room's deposit before moving to the next", %{conn: conn} do
      run_batch(conn, [open_operation(), pay("group-81", 10_000)])

      group = fetch_group(conn, "group-81")
      assert room_view(group, "room-a")["cash_paid_cents"] == 9_000
      assert room_view(group, "room-b")["cash_paid_cents"] == 1_000
      assert group["outstanding_deposit_cents"] == 9_500
    end

    test "credit continues filling where cash stopped and is tracked per room", %{conn: conn} do
      issue_lot(conn, "guest-22", "cancel-src", "2026-09-01", 5_000)

      run_batch(conn, [
        open_operation(),
        pay("group-81", 10_000),
        apply_credit("group-81", 2_000)
      ])

      group = fetch_group(conn, "group-81")
      assert room_view(group, "room-a")["cash_paid_cents"] == 9_000
      assert room_view(group, "room-a")["credit_paid_cents"] == 0
      assert room_view(group, "room-b")["cash_paid_cents"] == 1_000
      assert room_view(group, "room-b")["credit_paid_cents"] == 2_000
      assert group["cash_paid_cents"] == 10_000
      assert group["credit_paid_cents"] == 2_000
      assert group["deposit_paid_cents"] == 12_000

      assert_ledger(conn,
        cash_held_cents: 10_000,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )
    end
  end

  ## Settling selected rooms

  describe "cancel_rooms" do
    test "settles only the selected rooms with their allocated cash and credit", %{conn: conn} do
      issue_lot(conn, "guest-22", "cancel-src", "2026-09-01", 5_000)

      run_batch(conn, [
        open_operation(),
        pay("group-81", 10_000),
        apply_credit("group-81", 2_000)
      ])

      result =
        hd(
          run_batch(conn, [
            cancel_rooms(["room-b"], %{
              "operation_id" => "op-cancel-rooms-b",
              "expected_revision" => 3
            })
          ])
        )

      assert result == %{
               "operation_id" => "op-cancel-rooms-b",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 1_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      group = fetch_group(conn, "group-81")
      assert group["status"] == "active"
      assert room_view(group, "room-b")["status"] == "cancelled"
      assert room_view(group, "room-a")["cash_paid_cents"] == 9_000

      assert %{
               "lodging_total_cents" => 45_000,
               "deposit_due_cents" => 9_000,
               "deposit_paid_cents" => 9_000,
               "cash_paid_cents" => 9_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             } = group

      assert_ledger(conn,
        cash_held_cents: 9_000,
        cash_refunded_cents: 1_000,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )

      assert [%{"remaining_cents" => 5_500}] = fetch_guest_credit(conn, "guest-22")["lots"]

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] =
               run_batch(conn, [pay("group-81", 1, %{"operation_id" => "pay-after"})])
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        pay("group-81", 19_500),
        cancel_rooms(["room-b"], %{"operation_id" => "op-cr-b"})
      ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 9_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] = run_batch(conn, [cancel(%{"occurred_on" => "2026-11-26"})])

      group = fetch_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_due_cents"] == 0
      assert group["cash_paid_cents"] == 0

      assert_ledger(conn, cash_refunded_cents: 19_500, cash_held_cents: 0)
    end

    defp cancel(overrides) do
      Map.merge(
        %{
          "operation_id" => "op-cancel-rest",
          "type" => "cancel_group",
          "group_id" => "group-81"
        },
        overrides
      )
    end

    test "returns cancelled rooms in original order regardless of caller order", %{conn: conn} do
      run_batch(conn, [open_operation()])

      assert [%{"cancelled_room_ids" => ["room-a", "room-b"]}] =
               run_batch(conn, [cancel_rooms(["room-b", "room-a"])])
    end

    test "when no active rooms remain the group becomes cancelled", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        pay("group-81", 19_500)
      ])

      assert [%{"status" => "applied", "revision" => 3}] =
               run_batch(conn, [cancel_rooms(["room-b", "room-a"])])

      group = fetch_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_due_cents"] == 0
      assert group["cash_paid_cents"] == 0

      assert_ledger(conn, cash_refunded_cents: 19_500, cash_held_cents: 0)

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               run_batch(conn, [
                 cancel_rooms(["room-a"], %{"operation_id" => "op-too-late"})
               ])
    end

    test "computes the hotel-credit bonus once on the combined cash", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{
          "operation_id" => "open-tiny",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 125},
            %{"room_id" => "room-b", "nightly_rate_cents" => 125}
          ]
        }),
        pay("group-81", 25, %{"operation_id" => "pay-tiny-1"}),
        pay("group-81", 25, %{"operation_id" => "pay-tiny-2"})
      ])

      assert [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-a", "room-b"],
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 55,
                 "revision" => 4
               }
             ] =
               run_batch(conn, [
                 cancel_rooms(["room-b", "room-a"], %{
                   "refund_method" => "hotel_credit"
                 })
               ])

      # Combined 50 cents earns a 5 cent bonus (55 total); per-room rounding
      # would have paid 6.
      assert %{"available_cents" => 55} = fetch_guest_credit(conn, "guest-22")
      assert fetch_group(conn, "group-81")["status"] == "cancelled"
    end

    test "rejects anything but distinct active room ids of the group", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_operation(%{
          "operation_id" => "open-other",
          "group_id" => "g-other",
          "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 15_000}]
        })
      ])

      variants = [
        ["room-a", "room-a"],
        ["nope"],
        [],
        "room-a",
        nil,
        ["room-a", 42],
        ["room-z"]
      ]

      variants
      |> Enum.with_index()
      |> Enum.each(fn {room_ids, index} ->
        results =
          run_batch(conn, [
            cancel_rooms(room_ids, %{"operation_id" => "op-cr-bad-#{index}"})
          ])

        assert [%{"status" => "rejected", "code" => "invalid_rooms"}] = results
      end)

      assert fetch_group(conn, "group-81")["revision"] == 1

      run_batch(conn, [cancel_rooms(["room-a"], %{"operation_id" => "op-cr-first"})])

      assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
               run_batch(conn, [
                 cancel_rooms(["room-a"], %{"operation_id" => "op-cr-twice"})
               ])
    end

    test "hotel credit is not available for non-refundable selected rooms", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{"rate_plan" => "advance_purchase"}),
        pay("group-81", 10_000)
      ])

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] =
               run_batch(conn, [
                 cancel_rooms(["room-a"], %{"refund_method" => "hotel_credit"})
               ])

      group = fetch_group(conn, "group-81")
      assert group["status"] == "active"
      assert room_view(group, "room-a")["status"] == "active"
      assert group["revision"] == 2
    end

    test "restores only the settled rooms' applied credit to its lots", %{conn: conn} do
      issue_lot(conn, "guest-22", "cancel-src", "2026-09-01", 5_000)

      run_batch(conn, [
        open_operation(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 12_500},
            %{"room_id" => "room-b", "nightly_rate_cents" => 12_500}
          ]
        }),
        apply_credit("group-81", 3_000)
      ])

      assert room_view(fetch_group(conn, "group-81"), "room-a")["credit_paid_cents"] == 2_500
      assert room_view(fetch_group(conn, "group-81"), "room-b")["credit_paid_cents"] == 500

      assert [%{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 0}] =
               run_batch(conn, [cancel_rooms(["room-a"])])

      assert %{"available_cents" => 5_000} = fetch_guest_credit(conn, "guest-22")

      group = fetch_group(conn, "group-81")
      assert room_view(group, "room-b")["credit_paid_cents"] == 500
      assert group["credit_paid_cents"] == 500

      assert_ledger(conn,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )
    end

    test "an identical retry replays the stored result without settling again", %{conn: conn} do
      run_batch(conn, [open_operation(), pay("group-81", 5_000)])

      operation = cancel_rooms(["room-b"])
      [%{} = first] = run_batch(conn, [operation])

      assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
               run_batch(conn, [cancel_rooms(["room-b"], %{"operation_id" => "op-fresh"})])

      assert hd(run_batch(conn, [operation])) == first
      assert fetch_ledger(conn)["cash_refunded_cents"] == 0
    end
  end

  ## Reducing recorded cash

  describe "reduce_cash_payment" do
    setup :two_payment_funding

    test "removes held allocations in reverse fill order and reopens the deposit", %{
      conn: conn
    } do
      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "payment_operation_id" => "pay-group-81-10000",
                 "amount_cents" => 1_500,
                 "outstanding_deposit_cents" => 6_000,
                 "revision" => 4
               }
             ] =
               run_batch(conn, [
                 reduce("pay-group-81-10000", 1_500, %{"operation_id" => "op-reduce-1"})
               ])

      group = fetch_group(conn, "group-81")
      assert room_view(group, "room-a")["cash_paid_cents"] == 8_500
      assert room_view(group, "room-b")["cash_paid_cents"] == 5_000
      assert group["outstanding_deposit_cents"] == 6_000

      assert_ledger(conn,
        cash_held_cents: 13_500,
        cash_reduced_cents: 1_500
      )

      dispositions =
        Enum.map(
          allocations("group-81"),
          &{&1.payment_operation_id, &1.amount_cents, &1.disposition}
        )

      assert dispositions == [
               {"pay-group-81-10000", 8_500, "held"},
               {"pay-group-81-10000", 1_000, "reduced"},
               {"pay-group-81-5000", 5_000, "held"},
               {"pay-group-81-10000", 500, "reduced"}
             ]
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      run_batch(conn, [
        reduce("pay-group-81-10000", 1_500, %{"operation_id" => "op-reduce-1"}),
        reduce("pay-group-81-10000", 1_500, %{"operation_id" => "op-reduce-2"}),
        reduce("pay-group-81-10000", 7_000, %{"operation_id" => "op-reduce-3"})
      ])

      group = fetch_group(conn, "group-81")
      assert room_view(group, "room-a")["cash_paid_cents"] == 0
      assert room_view(group, "room-b")["cash_paid_cents"] == 5_000
      assert group["cash_paid_cents"] == 5_000
      assert group["outstanding_deposit_cents"] == 14_500
      assert fetch_ledger(conn)["cash_reduced_cents"] == 10_000

      assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
               run_batch(conn, [
                 reduce("pay-group-81-10000", 1, %{"operation_id" => "op-reduce-4"})
               ])
    end

    test "uses the documented rejection codes", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{"operation_id" => "op-open-known"}),
        pay("group-81", 999_999, %{"operation_id" => "pay-rejected"})
      ])

      reductions = [
        {"ghost-payment", 100, "operation_not_found"},
        {"op-open-known", 100, "payment_not_reducible"},
        {"pay-rejected", 100, "payment_not_reducible"},
        {"pay-group-81-10000", 0, "invalid_amount"},
        {"pay-group-81-10000", -5, "invalid_amount"},
        {"pay-group-81-10000", "100", "invalid_amount"},
        {"pay-group-81-10000", 1.5, "invalid_amount"},
        {"pay-group-81-10000", 999_999, "reduction_exceeds_held_cash"}
      ]

      reductions
      |> Enum.with_index()
      |> Enum.each(fn {{pid, amount, code}, index} ->
        assert [%{"status" => "rejected", "code" => ^code}] =
                 run_batch(conn, [
                   reduce(pid, amount, %{"operation_id" => "op-red-bad-#{index}"})
                 ])
      end)

      assert fetch_group(conn, "group-81")["revision"] == 3
    end

    test "a stale revision wins over the other domain rules", %{conn: conn} do
      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 99,
                 "actual_revision" => 3
               }
             ] =
               run_batch(conn, [
                 reduce("pay-group-81-10000", -1, %{"expected_revision" => 99})
               ])
    end

    test "retrying the original payment keeps returning its exact original result", %{
      conn: conn
    } do
      payment = pay("group-81", 4_000)
      [%{} = original] = run_batch(conn, [payment])

      run_batch(conn, [
        reduce("pay-group-81-4000", 2_000, %{"operation_id" => "op-reduce-part"}),
        pay("group-81", 2_000, %{"operation_id" => "pay-top-up"})
      ])

      assert hd(run_batch(conn, [payment])) == original

      assert fetch_group(conn, "group-81")["revision"] == 6
      assert fetch_payment(conn, "pay-group-81-4000")["held_cents"] == 2_000
      assert fetch_payment(conn, "pay-group-81-4000")["reduced_cents"] == 2_000
    end

    defp two_payment_funding(%{conn: conn}) do
      run_batch(conn, [
        open_operation(),
        pay("group-81", 10_000),
        pay("group-81", 5_000)
      ])

      {:ok, conn: conn}
    end

    test "an identical reduction retry replays its stored result", %{conn: conn} do
      reduction = reduce("pay-group-81-5000", 2_000)
      [%{} = first] = run_batch(conn, [reduction])

      assert hd(run_batch(conn, [reduction])) == first

      group = fetch_group(conn, "group-81")
      assert room_view(group, "room-b")["cash_paid_cents"] == 4_000
      assert fetch_ledger(conn)["cash_reduced_cents"] == 2_000
    end
  end

  ## Charging back a payment

  describe "charge_back_payment" do
    test "reclassifies every remaining disposition of the payment", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        pay("group-81", 4_000, %{"operation_id" => "pay-one"}),
        pay("group-81", 6_000, %{"operation_id" => "pay-two"}),
        cancel_rooms(["room-b"], %{"operation_id" => "op-cr-b"})
      ])

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "payment_operation_id" => "pay-two",
                 "charged_back_cents" => 6_000,
                 "outstanding_deposit_cents" => 5_000,
                 "revision" => 5
               }
             ] =
               run_batch(conn, [
                 charge_back("pay-two", %{"expected_revision" => 4})
               ])

      group = fetch_group(conn, "group-81")
      assert room_view(group, "room-a")["cash_paid_cents"] == 4_000
      assert group["cash_paid_cents"] == 4_000
      assert group["outstanding_deposit_cents"] == 5_000

      assert_ledger(conn,
        cash_held_cents: 4_000,
        cash_charged_back_cents: 6_000
      )

      assert fetch_payment(conn, "pay-two") == %{
               "payment_operation_id" => "pay-two",
               "original_group_id" => "group-81",
               "recorded_cents" => 6_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 6_000
             }

      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               run_batch(conn, [
                 charge_back("pay-two", %{"operation_id" => "op-cb-again"})
               ])

      assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
               run_batch(conn, [
                 reduce("pay-two", 1, %{"operation_id" => "op-red-after-cb"})
               ])

      assert [
               %{
                 "status" => "applied",
                 "charged_back_cents" => 4_000,
                 "outstanding_deposit_cents" => 9_000,
                 "revision" => 6
               }
             ] =
               run_batch(conn, [
                 charge_back("pay-one", %{"operation_id" => "op-cb-one"})
               ])

      assert_ledger(conn,
        cash_held_cents: 0,
        cash_charged_back_cents: 10_000
      )
    end

    test "an identical chargeback retry replays its stored result", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        pay("group-81", 4_000, %{"operation_id" => "pay-one"})
      ])

      operation = charge_back("pay-one")
      [%{} = first] = run_batch(conn, [operation])

      assert hd(run_batch(conn, [operation])) == first

      group = fetch_group(conn, "group-81")
      assert room_view(group, "room-a")["cash_paid_cents"] == 0
      assert group["revision"] == 3
      assert fetch_ledger(conn)["cash_charged_back_cents"] == 4_000
    end

    test "uses the documented rejection codes", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{"operation_id" => "op-open-known"}),
        pay("group-81", 999_999, %{"operation_id" => "pay-rejected"}),
        pay("group-81", 1_000, %{"operation_id" => "pay-ok"})
      ])

      chargebacks = [
        {"ghost-payment", "operation_not_found"},
        {"op-open-known", "payment_not_chargeable"},
        {"pay-rejected", "payment_not_chargeable"}
      ]

      chargebacks
      |> Enum.with_index()
      |> Enum.each(fn {{pid, code}, index} ->
        assert [%{"status" => "rejected", "code" => ^code}] =
                 run_batch(conn, [
                   charge_back(pid, %{"operation_id" => "op-cb-bad-#{index}"})
                 ])
      end)

      assert fetch_group(conn, "group-81")["revision"] == 2
    end

    test "charges back a payment whose group is already cancelled", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{"rate_plan" => "advance_purchase", "operation_id" => "open-ap"}),
        pay("group-81", 12_000),
        %{
          "operation_id" => "cancel-ap",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-30",
          "group_id" => "group-81"
        }
      ])

      assert_ledger(conn, cash_retained_cents: 12_000)

      assert [
               %{
                 "status" => "applied",
                 "charged_back_cents" => 12_000,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 4
               }
             ] =
               run_batch(conn, [
                 charge_back("pay-group-81-12000", %{"expected_revision" => 3})
               ])

      assert_ledger(conn,
        cash_retained_cents: 0,
        cash_charged_back_cents: 12_000
      )

      assert fetch_payment(conn, "pay-group-81-12000")["charged_back_cents"] == 12_000
    end
  end

  ## Credit entitlements and shortfalls

  describe "chargeback credit clawbacks" do
    # Converts two payments into one lot through a combined settlement:
    # pay-one funds room-a (2500), pay-two funds room-b (2500), and cancelling
    # both rooms refundably with hotel credit issues one lot worth 5500.
    defp converted_group(conn) do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 12_500},
        %{"room_id" => "room-b", "nightly_rate_cents" => 12_500}
      ]

      run_batch(conn, [
        open_operation(%{
          "operation_id" => "open-ent",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => rooms
        }),
        pay("group-81", 2_500, %{"operation_id" => "pay-one"}),
        pay("group-81", 2_500, %{"operation_id" => "pay-two"}),
        cancel_rooms(["room-a", "room-b"], %{
          "operation_id" => "op-cancel-all",
          "refund_method" => "hotel_credit"
        })
      ])
    end

    defp spending_group(conn, suffix, rate_plan \\ "flexible") do
      run_batch(conn, [
        open_operation(%{
          "operation_id" => "open-spend-" <> suffix,
          "group_id" => "g-spend-" <> suffix,
          "rate_plan" => rate_plan,
          "occurred_on" => "2026-10-05",
          "arrival_on" => "2028-06-10",
          "departure_on" => "2028-06-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 30_000}]
        })
      ])
    end

    test "entitlements telescope per payment in funding order", %{conn: conn} do
      converted_group(conn)
      spending_group(conn, "one")
      run_batch(conn, [apply_credit("g-spend-one", 5_200)])

      assert_ledger(conn,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )

      spend_revision_before = fetch_group(conn, "g-spend-one")["revision"]

      assert [%{"status" => "applied", "revision" => 5}] =
               run_batch(conn, [
                 charge_back("pay-two", %{"operation_id" => "cb-pay-two"})
               ])

      assert fetch_group(conn, "g-spend-one")["revision"] == spend_revision_before

      # The second payment's entitlement is bonus(5000) - bonus(2500) = 250;
      # it comes out of the lot's remaining 300.
      assert_ledger(conn,
        cash_charged_back_cents: 2_500,
        cash_converted_to_credit_cents: 2_500,
        credit_liability_cents: 5_250,
        credit_shortfall_cents: 0
      )

      assert [%{"status" => "applied", "revision" => 6}] =
               run_batch(conn, [
                 charge_back("pay-one", %{"operation_id" => "cb-pay-one"})
               ])

      assert_ledger(conn,
        cash_charged_back_cents: 5_000,
        cash_converted_to_credit_cents: 0,
        credit_liability_cents: 5_200,
        credit_shortfall_cents: 200
      )
    end

    test "unrecoverable clawback becomes a shortfall covered by applied credit", %{conn: conn} do
      converted_group(conn)
      spending_group(conn, "two")
      run_batch(conn, [apply_credit("g-spend-two", 5_300)])

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 charge_back("pay-two", %{"operation_id" => "cb-pay-two"})
               ])

      # Only 200 of the 250 entitlement was still available; the rest waits as
      # unrecovered clawback while 5200 from the lot still funds an active group.
      assert_ledger(conn,
        cash_charged_back_cents: 2_500,
        cash_converted_to_credit_cents: 2_500,
        credit_liability_cents: 5_300,
        credit_shortfall_cents: 50
      )

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] =
               run_batch(conn, [
                 %{
                   "operation_id" => "cancel-spend-two",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-11-01",
                   "group_id" => "g-spend-two",
                   "refund_method" => "cash"
                 }
               ])

      # Restoration absorbs the unrecovered clawback before becoming available.
      assert_ledger(conn,
        cash_charged_back_cents: 2_500,
        cash_converted_to_credit_cents: 2_500,
        credit_liability_cents: 5_250,
        credit_shortfall_cents: 0
      )

      assert %{"available_cents" => 5_250} = fetch_guest_credit(conn, "guest-22")
    end

    test "non-refundable settlement of applied credit reduces the shortfall", %{conn: conn} do
      converted_group(conn)
      spending_group(conn, "three", "advance_purchase")
      run_batch(conn, [apply_credit("g-spend-three", 5_300)])

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 charge_back("pay-two", %{"operation_id" => "cb-pay-two"})
               ])

      assert_ledger(conn,
        cash_charged_back_cents: 2_500,
        cash_converted_to_credit_cents: 2_500,
        credit_liability_cents: 5_300,
        credit_shortfall_cents: 50
      )

      assert [%{"status" => "applied", "retained_cents" => 0}] =
               run_batch(conn, [
                 %{
                   "operation_id" => "cancel-spend-three",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-11-01",
                   "group_id" => "g-spend-three"
                 }
               ])

      assert_ledger(conn,
        cash_charged_back_cents: 2_500,
        cash_converted_to_credit_cents: 2_500,
        credit_liability_cents: 0,
        credit_shortfall_cents: 0
      )
    end
  end

  ## Payment reconciliation

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports every disposition with all seven monetary fields", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        pay("group-81", 5_000, %{"operation_id" => "pay-full"})
      ])

      assert fetch_payment(conn, "pay-full") == %{
               "payment_operation_id" => "pay-full",
               "original_group_id" => "group-81",
               "recorded_cents" => 5_000,
               "held_cents" => 5_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end

    test "dispositions agree with the group and ledger views", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        pay("group-81", 4_000, %{"operation_id" => "pay-one"}),
        pay("group-81", 6_000, %{"operation_id" => "pay-two"}),
        cancel_rooms(["room-b"], %{"operation_id" => "op-cr-b"}),
        reduce("pay-one", 1_000, %{"operation_id" => "red-one"})
      ])

      statement = fetch_payment(conn, "pay-one")

      assert statement["recorded_cents"] ==
               statement["held_cents"] + statement["refunded_cents"] +
                 statement["retained_cents"] + statement["converted_to_credit_cents"] +
                 statement["reduced_cents"] + statement["charged_back_cents"]

      ledger = fetch_ledger(conn)

      assert ledger["cash_held_cents"] ==
               Enum.sum(
                 Enum.map(["pay-one", "pay-two"], fn pid ->
                   fetch_payment(conn, pid)["held_cents"]
                 end)
               )

      assert ledger["cash_reduced_cents"] == statement["reduced_cents"]
    end

    test "reading a statement never changes state", %{conn: conn} do
      run_batch(conn, [open_operation(), pay("group-81", 5_000)])
      before = {fetch_group(conn, "group-81"), fetch_ledger(conn)}

      assert fetch_payment(conn, "pay-group-81-5000") == fetch_payment(conn, "pay-group-81-5000")

      assert {fetch_group(conn, "group-81"), fetch_ledger(conn)} == before
    end

    test "unknown payments are not found", %{conn: conn} do
      response = get(conn, "/api/v1/payments/never-seen")

      assert response.status == 404
      assert json_response(response, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "records that are not applied cash payments cannot be reconciled", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{"operation_id" => "op-open-known"}),
        pay("group-81", 999_999, %{"operation_id" => "pay-rejected"})
      ])

      for pid <- ["op-open-known", "pay-rejected"] do
        response = get(conn, "/api/v1/payments/#{pid}")

        assert response.status == 422

        assert json_response(response, 422) == %{
                 "error" => %{"code" => "payment_not_reconcilable"}
               }
      end
    end
  end

  defp assert_ledger(conn, expectations) do
    assert fetch_ledger(conn) ==
             Map.merge(
               %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               },
               Map.new(expectations, fn {k, v} -> {Atom.to_string(k), v} end)
             )
  end
end
