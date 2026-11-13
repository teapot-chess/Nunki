defmodule NunkiWeb.CoreComponents do
  @moduledoc """
  The few pieces the pages share: the mark, icons, flash, buttons, a form
  field. Hand-made like the rest of the family; no component library, and no
  icon font - each icon is a line drawing on the mark's own 24 x 24 grid.
  """
  use Phoenix.Component
  use Gettext, backend: NunkiWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc "The mark (`NunkiWeb.Logo`): decorative, the name beside it says what it is."
  attr :class, :any, default: nil

  def logo(assigns) do
    assigns = assign(assigns, :inner, Phoenix.HTML.raw(NunkiWeb.Logo.inner()))

    ~H"""
    <svg class={["logo", @class]} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {@inner}
    </svg>
    """
  end

  @icons %{
    "ok" => ~s|<path d="M5 12.5l4.5 4.5L19 7.5"/>|,
    "error" => ~s|<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5M12 16.5v.5"/>|,
    "play" => ~s|<path d="M8 5.5v13l10.5-6.5z"/>|,
    "stop" => ~s|<rect x="6.5" y="6.5" width="11" height="11" rx="1"/>|,
    "pause" => ~s|<path d="M9 6v12M15 6v12"/>|,
    "blank" =>
      ~s|<rect x="3" y="4.5" width="18" height="12" rx="1.5" fill="currentColor"/><path d="M8.5 20h7M12 16.5V20"/>|,
    "speaker" =>
      ~s|<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"/>|,
    "timer" => ~s|<circle cx="12" cy="13" r="7.5"/><path d="M12 9v4l2.5 2M9.5 3h5"/>|,
    "screen" =>
      ~s|<rect x="3" y="4.5" width="18" height="12" rx="1.5"/><path d="M8.5 20h7M12 16.5V20"/>|,
    "expand" => ~s|<path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5"/>|,
    "trash" => ~s|<path d="M4.5 6.5h15M9.5 6.5V4h5v2.5M6.5 6.5l1 13h9l1-13"/>|,
    "link" =>
      ~s|<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>|,
    "help" =>
      ~s|<circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 .9-1 1.6v.4M12 17v.5"/>|,
    "update" => ~s|<path d="M12 4v11M7.5 10.5L12 15l4.5-4.5M5 19.5h14"/>|
  }

  @doc "An icon by name (see `@icons`); an unknown name is the help icon, not a crash."
  attr :name, :string, required: true
  attr :class, :any, default: nil

  def icon(assigns) do
    assigns = assign(assigns, :paths, Map.get(@icons, assigns.name, @icons["help"]))

    ~H"""
    <svg class={["icon", @class]} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {Phoenix.HTML.raw(@paths)}
    </svg>
    """
  end

  @doc "A flash message of one kind."
  attr :id, :string, default: nil
  attr :flash, :map, default: %{}
  attr :kind, :atom, values: [:info, :error]

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "##{@id}")}
      role={if @kind == :error, do: "alert", else: "status"}
      class={["flash", @kind == :error && "error"]}
    >
      <.icon name={if @kind == :error, do: "error", else: "ok"} />
      <p>{msg}</p>
      <span class="sr-only">{gettext("Dismiss")}</span>
    </div>
    """
  end

  @doc "A button. `variant` picks the weight; everything else goes to the element."
  attr :variant, :string, default: nil, values: [nil, "primary", "danger", "ghost"]
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(type disabled form name value)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@rest[:type] || "button"}
      class={["btn", @variant && "btn-#{@variant}", @class]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} />
      <span>{render_slot(@inner_block)}</span>
    </button>
    """
  end

  @doc """
  A form field: a label and the input under it, from a form field
  (`@form[:name]`). `type="select"` takes `options`; `type="checkbox"` puts
  the label beside the box.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField
  attr :options, :list, default: []
  attr :hint, :string, default: nil

  attr :rest, :global,
    include: ~w(autocomplete disabled maxlength placeholder required inputmode spellcheck)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <label class="check" for={@id}>
      <input type="hidden" name={@name} value="false" />
      <input type="checkbox" id={@id} name={@name} value="true" checked={@checked} {@rest} />
      <span>{@label}</span>
    </label>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id}>{@label}</label>
      <select id={@id} name={@name} {@rest}>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="hint">{@hint}</p>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id}>{@label}</label>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        {@rest}
      />
      <p :if={@hint} class="hint">{@hint}</p>
    </div>
    """
  end
end
