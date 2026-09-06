defmodule GroupStay.AcceptanceRoomAccountingTest do
  @moduledoc false

  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  describe "room-level accounting" do
    test "group responses expose each room's deposit and funding, with active-room totals" do
      issue_credit!(group_id: "group-src", amount: 5000, cancel_op: "op-cancel-src")

      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10000}),
        apply_credit_operation(%{
          "operation_id" => "op-credit",
          "amount_cents" => 5000,
          "occurred_on" => "2026-10-10"
        })
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15000,
                 "status" => "active",
                 "deposit_due_cents" => 9000,
                 "cash_paid_cents" => 9000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17500,
                 "status" => "active",
                 "deposit_due_cents" => 10500,
                 "cash_paid_cents" => 1000,
                 "credit_paid_cents" => 5000
               }
             ]

      assert data["lodging_total_cents"] == 97_500
      assert data["deposit_due_cents"] == 19_500
      assert data["deposit_paid_cents"] == 15_000
      assert data["cash_paid_cents"] == 10_000
      assert data["credit_paid_cents"] == 5000
      assert data["outstanding_deposit_cents"] == 4500
    end

    test "credit fills the active rooms' remaining deposit in room order" do
      issue_credit!(group_id: "group-src", amount: 5000, cancel_op: "op-cancel-src")

      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000}),
        apply_credit_operation(%{
          "operation_id" => "op-credit",
          "amount_cents" => 5000,
          "occurred_on" => "2026-10-10"
        })
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert json_response(conn, 200)["data"]["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15000,
                 "status" => "active",
                 "deposit_due_cents" => 9000,
                 "cash_paid_cents" => 5000,
                 "credit_paid_cents" => 4000
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 1000
               }
             ]
    end

    test "advance-purchase rooms expose their full lodging as the deposit" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1234}]
        })
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert [%{"deposit_due_cents" => 3702, "status" => "active"}] =
               json_response(conn, 200)["data"]["rooms"]
    end
  end

  describe "cancel_rooms" do
    test "settles the selected rooms and leaves the others untouched" do
      issue_credit!(group_id: "group-src", amount: 5000, cancel_op: "op-cancel-src")

      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10000}),
        apply_credit_operation(%{
          "operation_id" => "op-credit",
          "amount_cents" => 5000,
          "occurred_on" => "2026-10-10"
        })
      ])

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-1",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 1000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] =
               apply_operations!(build_conn(), [
                 cancel_rooms_operation(%{
                   "operation_id" => "op-cancel-rooms",
                   "room_ids" => ["room-b"]
                 })
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["status"] == "active"

      assert data["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15000,
                 "status" => "active",
                 "deposit_due_cents" => 9000,
                 "cash_paid_cents" => 9000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17500,
                 "status" => "cancelled",
                 "deposit_due_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]

      assert data["lodging_total_cents"] == 45_000
      assert data["deposit_due_cents"] == 9000
      assert data["deposit_paid_cents"] == 9000
      assert data["cash_paid_cents"] == 9000
      assert data["credit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 5500

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 9000,
               "cash_refunded_cents" => 1000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 5500,
               "credit_shortfall_cents" => 0
             }
    end

    test "returns cancelled_room_ids in the group's original room order" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-z", "nightly_rate_cents" => 1000},
            %{"room_id" => "room-a", "nightly_rate_cents" => 2000},
            %{"room_id" => "room-m", "nightly_rate_cents" => 3000}
          ]
        })
      ])

      assert [%{"cancelled_room_ids" => ["room-z", "room-m"]}] =
               apply_operations!(build_conn(), [
                 cancel_rooms_operation(%{
                   "operation_id" => "op-cancel-rooms",
                   "room_ids" => ["room-m", "room-z"]
                 })
               ])
    end

    test "rejects the complete operation with invalid_rooms" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        cancel_rooms_operation(%{
          "operation_id" => "op-cancel-first",
          "room_ids" => ["room-a"]
        })
      ])

      cases = [
        {%{"room_ids" => ["room-x"]}, "unknown room"},
        {%{"room_ids" => ["room-a", "room-a"]}, "duplicate rooms"},
        {%{"room_ids" => ["room-a"]}, "already cancelled room"},
        {%{"room_ids" => []}, "empty selection"},
        {%{"room_ids" => "room-b"}, "not a list"},
        {%{"room_ids" => [1, 2]}, "non-string identifiers"},
        {%{"room_ids" => nil}, "missing room ids"},
        {%{"room_ids" => ["room-b", "room-x"]}, "one valid, one unknown"}
      ]

      for {{attrs, label}, index} <- Enum.with_index(cases) do
        conn =
          submit(build_conn(), [
            cancel_rooms_operation(Map.put(attrs, "operation_id", "op-rooms-#{index}"))
          ])

        assert [result] = json_response(conn, 200)["results"]
        assert result["code"] == "invalid_rooms", "expected invalid_rooms for #{label}"
      end

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 2
    end

    test "a room identifier from another group is invalid" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-1",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"})
      ])

      conn =
        submit(build_conn(), [
          cancel_rooms_operation(%{"room_ids" => ["room-b"], "group_id" => "group-2"})
        ])

      assert [%{"code" => "invalid_rooms"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-2")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "unpaid deposit for the selected rooms ceases to be due" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        })
      ])

      assert [%{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 0}] =
               apply_operations!(build_conn(), [
                 cancel_rooms_operation(%{"room_ids" => ["room-b"]})
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["deposit_due_cents"] == 9000
      assert data["outstanding_deposit_cents"] == 9000
      assert data["status"] == "active"
    end

    test "the group becomes cancelled when no active rooms remain" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4000}),
        cancel_rooms_operation(%{"operation_id" => "op-cancel-a", "room_ids" => ["room-b"]}),
        cancel_rooms_operation(%{"operation_id" => "op-cancel-b", "room_ids" => ["room-a"]})
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["status"] == "cancelled"
      assert data["revision"] == 4
      assert data["lodging_total_cents"] == 0
      assert data["deposit_due_cents"] == 0
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0

      conn =
        submit(build_conn(), [
          cancel_rooms_operation(%{"operation_id" => "op-cancel-again", "room_ids" => ["room-a"]})
        ])

      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end

    test "the hotel-credit bonus is computed once on the combined cash" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "occurred_on" => "2026-12-10",
          "arrival_on" => "2026-12-24",
          "departure_on" => "2026-12-25",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 3060},
            %{"room_id" => "room-b", "nightly_rate_cents" => 3070}
          ]
        }),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-12-10",
          "amount_cents" => 612
        }),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-12-10",
          "amount_cents" => 614
        })
      ])

      # 612 and 614 each round their own bonus down (673 and 675), but the
      # combined 1226 rounds up to 1349.
      assert [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 1349,
                 "cancelled_room_ids" => ["room-a", "room-b"]
               }
             ] =
               apply_operations!(build_conn(), [
                 cancel_rooms_operation(%{
                   "operation_id" => "op-cancel-rooms",
                   "occurred_on" => "2026-12-10",
                   "room_ids" => ["room-a", "room-b"],
                   "refund_method" => "hotel_credit"
                 })
               ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert [%{"remaining_cents" => 1349, "source_operation_id" => "op-cancel-rooms"}] =
               json_response(conn, 200)["data"]["lots"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["status"] == "cancelled"
    end

    test "hotel credit is rejected for non-refundable selected rooms" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4000})
      ])

      conn =
        submit(build_conn(), [
          cancel_rooms_operation(%{
            "operation_id" => "op-cancel-rooms",
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit"
          })
        ])

      assert [%{"code" => "refund_method_not_available"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["status"] == "active"
    end

    test "non-refundable settlement retains the selected rooms' cash" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10000}),
        cancel_rooms_operation(%{
          "operation_id" => "op-cancel-rooms",
          "occurred_on" => "2026-11-27",
          "room_ids" => ["room-b"]
        })
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["cash_paid_cents"] == 9000
      assert data["deposit_paid_cents"] == 9000
      assert data["outstanding_deposit_cents"] == 0

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_retained_cents"] == 1000
    end

    test "cancel_group settles only the remaining active rooms" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 9000}),
        cancel_rooms_operation(%{"operation_id" => "op-cancel-a", "room_ids" => ["room-a"]})
      ])

      assert [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] =
               apply_operations!(build_conn(), [
                 cancel_operation(%{"operation_id" => "op-cancel-rest"})
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["status"] == "cancelled"
      assert data["deposit_paid_cents"] == 0

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 9000
    end

    test "follows the revision contract" do
      apply_operations!(build_conn(), [open_group_operation(%{"operation_id" => "op-open"})])

      conn =
        submit(build_conn(), [
          cancel_rooms_operation(%{
            "operation_id" => "op-cancel-rooms",
            "expected_revision" => 99
          })
        ])

      assert [
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 99,
                 "actual_revision" => 1
               }
             ] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          cancel_rooms_operation(%{
            "operation_id" => "op-cancel-rooms-2",
            "expected_revision" => 1
          })
        ])

      assert [%{"status" => "applied", "revision" => 2}] = json_response(conn, 200)["results"]
    end

    test "cancel_rooms is durably idempotent" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10000})
      ])

      original =
        [
          cancel_rooms_operation(%{
            "operation_id" => "op-cancel-rooms",
            "room_ids" => ["room-b"]
          })
        ]
        |> submit_first()

      conn =
        submit(build_conn(), [
          cancel_rooms_operation(%{
            "operation_id" => "op-cancel-rooms",
            "room_ids" => ["room-b"]
          })
        ])

      assert json_response(conn, 200)["results"] == [original]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["status"] == "active"
      assert data["revision"] == 3
      assert data["cash_paid_cents"] == 9000

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_refunded_cents"] == 1000
    end

    test "rejects operations for missing or inactive groups" do
      conn = submit(build_conn(), [cancel_rooms_operation(%{"group_id" => "nope"})])
      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]

      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        cancel_operation(%{"operation_id" => "op-cancel"})
      ])

      conn =
        submit(build_conn(), [
          cancel_rooms_operation(%{"operation_id" => "op-cancel-rooms-2"})
        ])

      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end
  end

  defp submit_first(operations) do
    conn = submit(build_conn(), operations)
    assert [result] = json_response(conn, 200)["results"]
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end

  defp issue_credit!(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    amount = Keyword.fetch!(opts, :amount)
    cancel_op = Keyword.fetch!(opts, :cancel_op)

    apply_operations!(build_conn(), [
      open_group_operation(%{
        "group_id" => group_id,
        "operation_id" => "op-open-#{group_id}",
        "occurred_on" => "2026-09-01",
        "arrival_on" => "2026-11-20",
        "departure_on" => "2026-11-23"
      }),
      payment_operation(%{
        "group_id" => group_id,
        "operation_id" => "op-pay-#{group_id}",
        "occurred_on" => "2026-09-02",
        "amount_cents" => amount
      }),
      cancel_operation(%{
        "group_id" => group_id,
        "operation_id" => cancel_op,
        "occurred_on" => "2026-11-01",
        "refund_method" => "hotel_credit"
      })
    ])
  end
end
