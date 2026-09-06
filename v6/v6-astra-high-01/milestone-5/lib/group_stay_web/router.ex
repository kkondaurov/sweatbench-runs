defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", GroupStayWeb do
    pipe_through :api

    post "/partner-batches", PartnerController, :create
    get "/groups/:group_id", PartnerController, :show
    get "/payments/:payment_operation_id", PartnerController, :payment
    get "/operations/:operation_id", PartnerController, :operation
    get "/guests/:guest_id/credit", PartnerController, :credit
    get "/ledger", PartnerController, :ledger
  end
end
