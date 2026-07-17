defmodule Slink.BlockKit do
  @moduledoc """
  Plain functions that build Block Kit maps — no DSL, no macros.

  Hand-writing block maps is the most verbose part of any bot. These builders
  return exactly the maps Slack expects, so they mix freely with hand-written
  ones and drop straight into `reply/3`'s `blocks:` or a modal view:

      import Slink.BlockKit

      reply(context, "Ready to deploy?",
        blocks: [
          header("Deploy"),
          section("*prod* is 3 commits behind — ship it?"),
          actions([
            button("Deploy", action_id: "deploy", value: "prod", style: "primary"),
            button("Diff", action_id: "diff")
          ])
        ])

  A modal for `open_modal/2`:

      modal("Settings", [
        input("Email", plain_text_input(action_id: "email")),
        input("Plan", static_select("Choose…", [option("Free", "free"), option("Pro", "pro")],
          action_id: "plan"))
      ], submit: "Save", callback_id: "settings")

  Text defaults to `mrkdwn` where Slack allows it (sections, context) and
  `plain_text` where Slack requires it (headers, buttons, titles). Every
  builder takes only the common options; anything more exotic, write the map —
  they compose.
  """

  ## Text objects

  @doc ~S|A `mrkdwn` text object: `%{type: "mrkdwn", text: text}`.|
  def mrkdwn(text), do: %{type: "mrkdwn", text: text}

  @doc ~S|A `plain_text` text object. Option: `emoji:` (default `true`).|
  def plain_text(text, opts \\ []) do
    %{type: "plain_text", text: text, emoji: Keyword.get(opts, :emoji, true)}
  end

  ## Blocks

  @doc "A `header` block. `text` is plain text (Slack requires it here)."
  def header(text), do: %{type: "header", text: plain_text(text)}

  @doc """
  A `section` block. `text` is mrkdwn (pass a text object to override).

  Options: `fields:` (a list of strings — each becomes mrkdwn — or text
  objects), `accessory:` (an element, e.g. a `button/2`), `block_id:`.
  """
  def section(text, opts \\ []) do
    %{type: "section", text: text_object(text)}
    |> put_option(:fields, opts[:fields] && Enum.map(opts[:fields], &text_object/1))
    |> put_option(:accessory, opts[:accessory])
    |> put_option(:block_id, opts[:block_id])
  end

  @doc "A `divider` block."
  def divider, do: %{type: "divider"}

  @doc """
  A `context` block: small, muted text/images under a message.

  `elements` is a list of strings (each becomes mrkdwn) or element maps.
  """
  def context(elements) when is_list(elements) do
    %{type: "context", elements: Enum.map(elements, &text_object/1)}
  end

  @doc "An `image` block. Options: `title:` (plain text), `block_id:`."
  def image(url, alt_text, opts \\ []) do
    %{type: "image", image_url: url, alt_text: alt_text}
    |> put_option(:title, opts[:title] && plain_text(opts[:title]))
    |> put_option(:block_id, opts[:block_id])
  end

  @doc "An `actions` block holding interactive `elements` (buttons, selects…)."
  def actions(elements) when is_list(elements), do: %{type: "actions", elements: elements}

  @doc """
  An `input` block (for modals): a labelled form `element`.

  Options: `optional:` (default `false`), `hint:` (plain text), `block_id:`.
  """
  def input(label, element, opts \\ []) do
    %{type: "input", label: plain_text(label), element: element}
    |> put_option(:optional, opts[:optional])
    |> put_option(:hint, opts[:hint] && plain_text(opts[:hint]))
    |> put_option(:block_id, opts[:block_id])
  end

  ## Elements

  @doc """
  A `button` element. `text` is plain text.

  Options: `action_id:` (how the click arrives at your handler — see
  `Slink.Event.action_id/1`), `value:` (rides along with the click),
  `style:` (`"primary"` / `"danger"`), `url:`.
  """
  def button(text, opts \\ []) do
    %{type: "button", text: plain_text(text)}
    |> put_option(:action_id, opts[:action_id])
    |> put_option(:value, opts[:value])
    |> put_option(:style, opts[:style])
    |> put_option(:url, opts[:url])
  end

  @doc """
  A `static_select` menu. Build `options` with `option/2`.

  Options: `action_id:`, `initial_option:`.
  """
  def static_select(placeholder, options, opts \\ []) do
    %{type: "static_select", placeholder: plain_text(placeholder), options: options}
    |> put_option(:action_id, opts[:action_id])
    |> put_option(:initial_option, opts[:initial_option])
  end

  @doc ~S|An option for a select menu: `option("Pro plan", "pro")`.|
  def option(text, value), do: %{text: plain_text(text), value: value}

  @doc """
  A `plain_text_input` element (for `input/3` blocks in modals).

  Options: `action_id:`, `multiline:`, `placeholder:` (plain text),
  `initial_value:`.
  """
  def plain_text_input(opts \\ []) do
    %{type: "plain_text_input"}
    |> put_option(:action_id, opts[:action_id])
    |> put_option(:multiline, opts[:multiline])
    |> put_option(:placeholder, opts[:placeholder] && plain_text(opts[:placeholder]))
    |> put_option(:initial_value, opts[:initial_value])
  end

  ## Views

  @doc """
  A modal view for `Slink.open_modal/2` / `Slink.API.open_view/3`.

  Options: `submit:` and `close:` (button labels, plain text),
  `callback_id:` (how the submission arrives — see
  `Slink.Event.callback_id/1`), `private_metadata:`.
  """
  def modal(title, blocks, opts \\ []) when is_list(blocks) do
    %{type: "modal", title: plain_text(title), blocks: blocks}
    |> put_option(:submit, opts[:submit] && plain_text(opts[:submit]))
    |> put_option(:close, opts[:close] && plain_text(opts[:close]))
    |> put_option(:callback_id, opts[:callback_id])
    |> put_option(:private_metadata, opts[:private_metadata])
  end

  # A bare string becomes mrkdwn; an already-built text object passes through.
  defp text_object(text) when is_binary(text), do: mrkdwn(text)
  defp text_object(%{} = object), do: object

  defp put_option(map, _key, nil), do: map
  defp put_option(map, key, value), do: Map.put(map, key, value)
end
