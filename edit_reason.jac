"""The reason the web page logs for its deck edits, which asks for none. Its
own module so the client bundle takes only this, not all of `decks.jac`."""

glob WEB_EDIT_REASON: str = "Edited in the app";

"""The same, for the web page's changes to a collection."""
glob WEB_COLLECTION_REASON: str = "Changed in the app";
