defmodule PhoenixAppWeb.InvoicesLive do
  @moduledoc """
  An organization's invoices. The router lets in only users who may view
  them there; updating takes `invoice: update`, checked when it happens.
  """
  use PhoenixAppWeb, :live_view

  alias Authmk.Plugins.Gate

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"organization_id" => organization_id}, _uri, socket) do
    abilities =
      Gate.abilities(
        PhoenixApp.Auth,
        socket.assigns.current_user,
        {:organization, organization_id}
      )

    {:noreply,
     assign(socket,
       organization_id: organization_id,
       can_update: "update" in Map.get(abilities, "invoice", []),
       message: nil
     )}
  end

  @impl true
  def handle_event("approve", _params, socket) do
    resource = {:organization, socket.assigns.organization_id}

    message =
      case Gate.authorize(
             PhoenixApp.Auth,
             socket.assigns.current_user,
             {:invoice, :update},
             resource
           ) do
        :ok -> "Approved"
        {:error, _forbidden} -> "You can't approve invoices"
      end

    {:noreply, assign(socket, :message, message)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-semibold">Invoices</h1>
      <p :if={@message} id="message">{@message}</p>
      <button :if={@can_update} id="approve" phx-click="approve" class="btn btn-primary mt-4">
        Approve
      </button>
    </Layouts.app>
    """
  end
end
