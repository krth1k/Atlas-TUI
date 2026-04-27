from textual.app import App
from textual import on
from textual.containers import ScrollableContainer
from textual.reactive import reactive
from textual.widgets import Header, Footer, Button, Static, Digits

from time import monotonic


class TimeClock(Digits):
    """Timer for the stopwatch"""

    time_elapsed = reactive(0)

    def on_mount(self):
        self.timer = self.set_interval(1 / 144, self.update_time_elapsed, pause=True)

    def update_time_elapsed(self):
        self.time_elapsed = monotonic() - self.start_time

    def watch_time_elapsed(self):
        time = self.time_elapsed
        time, seconds = divmod(time, 60)
        hours, minutes = divmod(time, 60)
        time_string = f"{hours:02.0f}:{minutes:02.0f}:{seconds:05.2f}"
        self.update(time_string)

    def start(self):
        self.start_time = monotonic() - self.time_elapsed
        self.timer.resume()

    def stop(self):
        self.time_elapsed = monotonic() - self.start_time
        self.timer.pause()

    def reset(self):
        self.time_elapsed = 0


class Tabs(Static):
    """Tabs for swtiching through"""

    @on(Button.Pressed, "#start")
    def start_stopwatch(self):
        self.add_class("started")
        self.query_one(TimeClock).start()

    @on(Button.Pressed, "#stop")
    def stop_stopwatch(self):
        self.remove_class("started")
        self.query_one(TimeClock).stop()

    @on(Button.Pressed, "#reset")
    def reset_stopwatch(self):
        self.remove_class("started")
        self.query_one(TimeClock).reset()

    def compose(self):
        yield Button("Start", id="start", variant="primary")
        yield Button("Stop", id="stop", variant="error")
        yield TimeClock("00:00:00.00", id="timeclock")
        yield Button("Reset", id="reset", variant="warning")


class Atlas(App):
    """A TUI app to showcase portfolio."""

    BINDINGS = [
        # ("key", "function name but without action_", "Description")
        ("d", "toggle_dark_mode", "Toggle Dark Mode"),
    ]

    CSS_PATH = "main.tcss"

    def compose(self):
        """What are the widgets this App is made up of"""
        yield Header()
        yield Footer()
        with ScrollableContainer(id="stopwatch_area"):
            yield Tabs()
            yield Tabs()
            yield Tabs()
        yield Button("Stop All", id="stop_all")

    # Actions are functions that are called when a keybinding is activated
    def action_toggle_dark_mode(self):
        """Toggle bettwen light and dark mode"""
        self.theme = (
            "textual-dark" if self.theme == "textual-light" else "textual-light"
        )


def main():
    """Main function to run the app."""
    app = Atlas()
    app.run()


if __name__ == "__main__":
    main()
