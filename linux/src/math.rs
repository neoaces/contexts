//! A math block, like `MathPreview.swift`: reading shows only the rendered
//! formula; editing adds the source line above and sets the formula in a
//! slightly darker well. Source that fails to parse stays visible, so the
//! block is never just an error.

use std::rc::Rc;

use gtk::prelude::*;
use ratex_gtk4::RatexFormula;

use crate::editor::{Editor, Kind};

/// Pixels, like the Mac's points.
const FONT_SIZE: f64 = 18.0;
const MINIMUM_FONT_SIZE: f64 = 12.0;

pub struct MathView {
    pub root: gtk::Box,
    pub source: Rc<Editor>,
    well: gtk::Box,
    formula: RatexFormula,
    error: gtk::Label,
    /// Width the formula may take before it shrinks, then scrolls.
    available: i32,
}

impl MathView {
    pub fn new(available: i32) -> MathView {
        let source = Editor::new(Kind::Math);
        let formula = RatexFormula::new();
        formula.set_display_mode(true);
        formula.set_font_size(FONT_SIZE);
        formula.set_halign(gtk::Align::Center);
        formula.set_valign(gtk::Align::Center);
        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::External)
            .vscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .child(&formula)
            .build();
        let error = gtk::Label::builder().wrap(true).justify(gtk::Justification::Center).build();
        error.add_css_class("dim-label");
        error.add_css_class("caption");
        let well = gtk::Box::new(gtk::Orientation::Vertical, 0);
        well.add_css_class("contexts-math");
        well.append(&scroller);
        well.append(&error);
        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        root.append(&source.view);
        root.append(&well);
        MathView { root, source, well, formula, error, available }
    }

    pub fn update(&self, latex: &str, editing: bool) {
        if self.formula.latex() != latex {
            self.formula.set_latex(latex);
            self.fit();
        }
        let message = self.formula.error_message().filter(|_| !latex.trim().is_empty());
        self.error.set_label(message.as_deref().unwrap_or_default());
        self.error.set_visible(message.is_some());
        self.formula.set_visible(message.is_none());
        self.source.view.set_visible(editing || message.is_some());
        self.well.set_visible(editing || !latex.trim().is_empty());
        if editing {
            self.well.add_css_class("editing");
        } else {
            self.well.remove_css_class("editing");
        }
    }

    /// The largest size, down to the floor, at which the formula fits; past that it scrolls.
    fn fit(&self) {
        self.formula.set_font_size(FONT_SIZE);
        let (_, natural, ..) = self.formula.measure(gtk::Orientation::Horizontal, -1);
        if natural > self.available && natural > 0 {
            let size = FONT_SIZE * self.available as f64 / natural as f64;
            self.formula.set_font_size(size.max(MINIMUM_FONT_SIZE));
        }
    }
}
