// The project, tags and note fields, shared by the toolbar panel and the
// notice's Change… panel. Everything shown is set as text, never as HTML.
"use strict";

(function () {
  if (globalThis.BenchBookForm) return;

  function el(tag, props = {}, children = []) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (key === "text") node.textContent = value;
      else if (key in node) node[key] = value;
      else node.setAttribute(key, value);
    }
    for (const child of children) if (child) node.append(child);
    return node;
  }

  let counter = 0;

  // state: { projects: [{ id, name, detail }], activeProjectID, tags: [names] }
  // Returns { element, values(), focus() }.
  function build(state, defaults = {}) {
    const id = `benchbook-${++counter}`;

    const project = el("select", { id: `${id}-project`, className: "bb-input" });
    for (const p of state.projects || []) {
      project.append(el("option", { value: p.id, text: p.name, title: p.detail || "" }));
    }
    project.value = defaults.projectID || state.activeProjectID || (state.projects[0] && state.projects[0].id) || "";

    const suggestions = el("datalist", { id: `${id}-tags-list` });
    const tags = el("input", {
      id: `${id}-tags`,
      className: "bb-input",
      type: "text",
      placeholder: "Optional, separated by commas",
      autocomplete: "off",
      spellcheck: false,
    });
    tags.setAttribute("list", suggestions.id);
    // Suggests tags for the word being typed, keeping the ones before it.
    tags.addEventListener("input", () => {
      const parts = tags.value.split(",");
      const typed = parts.pop().trim().toLowerCase();
      const chosen = new Set(parts.map((p) => p.trim().toLowerCase()));
      const before = parts.length ? parts.map((p) => p.trim()).join(", ") + ", " : "";
      suggestions.replaceChildren(
        ...(state.tags || [])
          .filter((name) => !chosen.has(name.toLowerCase()) && (!typed || name.toLowerCase().includes(typed)))
          .slice(0, 12)
          .map((name) => el("option", { value: before + name }))
      );
    });

    const note = el("textarea", { id: `${id}-note`, className: "bb-input", rows: 3, placeholder: "Optional" });

    const row = (label, field) => el("div", { className: "bb-row" }, [el("label", { htmlFor: field.id, text: label }), field]);
    const element = el("div", { className: "bb-form" }, [
      row("Project", project),
      row("Tags", tags),
      suggestions,
      row("Note", note),
    ]);

    return {
      element,
      values() {
        return {
          projectID: project.value,
          tags: tags.value.split(",").map((t) => t.trim()).filter(Boolean),
          note: note.value.trim(),
        };
      },
      focus() {
        project.focus();
      },
    };
  }

  // Shared look for the fields, in light and dark mode.
  const css = `
    .bb-form { display: grid; gap: 8px; }
    .bb-row { display: grid; grid-template-columns: 64px 1fr; align-items: center; gap: 8px; }
    .bb-row label { color: var(--bb-secondary); text-align: right; }
    .bb-row:last-of-type { align-items: start; }
    .bb-row:last-of-type label { padding-top: 4px; }
    .bb-input {
      font: inherit; color: inherit; box-sizing: border-box; width: 100%; min-width: 0;
      padding: 4px 7px; border-radius: 6px; border: 1px solid var(--bb-border);
      background: var(--bb-field);
    }
    textarea.bb-input { resize: vertical; min-height: 48px; }
    .bb-input:focus { outline: 3px solid var(--bb-focus); outline-offset: 0; border-color: var(--bb-accent); }
    .bb-button {
      font: inherit; padding: 4px 12px; border-radius: 6px; border: 1px solid var(--bb-border);
      background: var(--bb-field); color: inherit; cursor: default;
    }
    .bb-button.bb-primary { background: var(--bb-accent); border-color: var(--bb-accent); color: #fff; }
    .bb-button:disabled { opacity: 0.5; }
    .bb-button:focus-visible { outline: 3px solid var(--bb-focus); outline-offset: 1px; }
  `;

  // Colours for the fields, set on the element that holds the form.
  const colors = `
    --bb-text: #1d1d1f; --bb-secondary: #6e6e73; --bb-border: rgba(0, 0, 0, 0.16);
    --bb-field: #ffffff; --bb-accent: #0a84ff; --bb-focus: rgba(10, 132, 255, 0.35);
    --bb-surface: rgba(250, 250, 252, 0.98);
  `;
  const darkColors = `
    --bb-text: #f5f5f7; --bb-secondary: #a1a1a6; --bb-border: rgba(255, 255, 255, 0.18);
    --bb-field: rgba(255, 255, 255, 0.08); --bb-accent: #0a84ff; --bb-focus: rgba(10, 132, 255, 0.5);
    --bb-surface: rgba(40, 40, 42, 0.98);
  `;

  globalThis.BenchBookForm = { build, el, css, colors, darkColors };
})();
