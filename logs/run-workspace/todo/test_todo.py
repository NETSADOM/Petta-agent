import os
import json
import unittest
from io import StringIO
from contextlib import redirect_stdout

# Import the functions from todo module
import todo

class TestTodo(unittest.TestCase):
    def setUp(self):
        # Ensure a clean state before each test
        if os.path.exists(todo.DATA_FILE):
            os.remove(todo.DATA_FILE)

    def test_add_item(self):
        # Capture output
        out = StringIO()
        with redirect_stdout(out):
            todo.add_item("Test item")
        output = out.getvalue().strip()
        self.assertIn("Added item 1: Test item", output)
        # Verify file contents
        with open(todo.DATA_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["id"], 1)
        self.assertEqual(data[0]["description"], "Test item")
        self.assertFalse(data[0]["done"])

    def test_list_items(self):
        # Add two items
        todo.add_item("First")
        todo.add_item("Second")
        out = StringIO()
        with redirect_stdout(out):
            todo.list_items()
        output = out.getvalue().strip().splitlines()
        self.assertIn("1. [✗] First", output)
        self.assertIn("2. [✗] Second", output)

    def test_mark_done(self):
        todo.add_item("To be done")
        out = StringIO()
        with redirect_stdout(out):
            todo.mark_done(1)
        self.assertIn("Marked item 1 as done.", out.getvalue().strip())
        with open(todo.DATA_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
        self.assertTrue(data[0]["done"])

    def test_remove_item(self):
        todo.add_item("Delete me")
        out = StringIO()
        with redirect_stdout(out):
            todo.remove_item(1)
        self.assertIn("Removed item 1.", out.getvalue().strip())
        self.assertFalse(os.path.exists(todo.DATA_FILE))

    def test_nonexistent_done(self):
        out = StringIO()
        with redirect_stdout(out):
            todo.mark_done(99)
        self.assertIn("Item 99 not found.", out.getvalue().strip())

    def test_nonexistent_remove(self):
        out = StringIO()
        with redirect_stdout(out):
            todo.remove_item(99)
        self.assertIn("Item 99 not found.", out.getvalue().strip())

if __name__ == "__main__":
    unittest.main()
