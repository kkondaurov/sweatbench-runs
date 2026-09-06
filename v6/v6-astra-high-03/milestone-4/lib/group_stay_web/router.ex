defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", GroupStayWeb do
    pipe_through :api

    post "/partner-batches", PartnerController, :create_batch
    get "/groups/:group_id", PartnerController, :show_group
    get "/operations/:operation_id", PartnerController, :show_operation
    get "/guests/:guest_id/credit", PartnerController, :guest_credit
    get "/payments/:payment_operation_id", PartnerController, :show_payment
    get "/ledger", PartnerController, :ledger
  end
end
