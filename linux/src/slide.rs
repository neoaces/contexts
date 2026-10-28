//! A row's card that narrows from the right to uncover a Delete button, by the
//! minus button in delete mode (and later a two-finger swipe). Narrowing, not
//! sliding, keeps the card whole: its text rewraps instead of being cut off.

use std::cell::{Cell, RefCell};

use gtk::glib;
use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{graphene, gsk};

/// Gap between the slid card and the Delete button.
const GAP: f64 = 8.0;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct SlideBin {
        pub card: RefCell<Option<gtk::Widget>>,
        pub action: RefCell<Option<gtk::Widget>>,
        /// How much narrower the card is; 0 or negative.
        pub offset: Cell<f64>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for SlideBin {
        const NAME: &'static str = "ContextsSlideBin";
        type Type = super::SlideBin;
        type ParentType = gtk::Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.set_accessible_role(gtk::AccessibleRole::Group);
        }
    }

    impl ObjectImpl for SlideBin {
        fn constructed(&self) {
            self.parent_constructed();
            self.obj().set_overflow(gtk::Overflow::Hidden);
        }

        fn dispose(&self) {
            for child in [self.action.take(), self.card.take()].into_iter().flatten() {
                child.unparent();
            }
        }
    }

    impl SlideBin {
        fn card_width(&self, card: &gtk::Widget, width: i32) -> i32 {
            let (minimum, ..) = card.measure(gtk::Orientation::Horizontal, -1);
            ((width as f64 + self.offset.get()).round() as i32).max(minimum)
        }
    }

    impl WidgetImpl for SlideBin {
        fn request_mode(&self) -> gtk::SizeRequestMode {
            gtk::SizeRequestMode::HeightForWidth
        }

        /// Only the card counts, at its current width; the action fits into what it leaves.
        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            let Some(card) = &*self.card.borrow() else { return (0, 0, -1, -1) };
            match orientation {
                gtk::Orientation::Vertical if for_size >= 0 => card.measure(orientation, self.card_width(card, for_size)),
                _ => card.measure(orientation, for_size),
            }
        }

        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            let offset = self.offset.get();
            if let Some(card) = &*self.card.borrow() {
                card.allocate(self.card_width(card, width), height, baseline, None);
            }
            if let Some(action) = &*self.action.borrow() {
                let revealed = (-offset - GAP).max(0.0).round() as i32;
                action.set_child_visible(revealed > 0);
                if revealed > 0 {
                    // At least its minimum width; the overflow past the edge is clipped.
                    let (minimum, ..) = action.measure(gtk::Orientation::Horizontal, height);
                    let x = (width - revealed) as f32;
                    let place = gsk::Transform::new().translate(&graphene::Point::new(x, 0.0));
                    action.allocate(revealed.max(minimum), height, -1, Some(place));
                }
            }
        }
    }
}

glib::wrapper! {
    pub struct SlideBin(ObjectSubclass<imp::SlideBin>) @extends gtk::Widget;
}

impl SlideBin {
    pub fn new(card: &impl IsA<gtk::Widget>, action: &impl IsA<gtk::Widget>) -> SlideBin {
        let bin: SlideBin = glib::Object::new();
        action.set_parent(&bin);
        card.set_parent(&bin);
        bin.imp().action.replace(Some(action.clone().upcast()));
        bin.imp().card.replace(Some(card.clone().upcast()));
        bin
    }

    pub fn offset(&self) -> f64 {
        self.imp().offset.get()
    }

    pub fn set_offset(&self, offset: f64) {
        self.imp().offset.set(offset);
        self.queue_resize();
    }
}
