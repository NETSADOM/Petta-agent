import unittest
import os
import json
import sys
import tempfile
import shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import todo


class TestTodo(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.orig_data_file = todo.DATA_FILE
        todo.DATA_FILE = os.path.join(self.tmpdir, 'todo.json')

    def tearDown(self):
        todo.DATA_FILE = self.orig_data_file
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_load_empty(self):
        items = todo.load_data()
        self.assertEqual(items, [])

    def test_add(self):
        todo.add('Buy milk')
        items = todo.load_data()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]['title'], 'Buy milk')
        self.assertFalse(items[0]['done'])

    def test_list(self):
        todo.add('Task 1')
        todo.add('Task 2')
        items = todo.load_data()
        self.assertEqual(len(items), 2)

    def test_done(self):
        todo.add('Task 1')
        todo.done(1)
        items = todo.load_data()
        self.assertTrue(items[0]['done'])

    def test_done_invalid_index(self):
        todo.add('Task 1')
        todo.done(99)
        items = todo.load_data()
        self.assertFalse(items[0]['done'])

    def test_remove(self):
        todo.add('Task A')
        todo.add('Task B')
        todo.remove(1)
        items = todo.load_data()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]['title'], 'Task B')

    def test_remove_invalid_index(self):
        todo.add('Task X')
        todo.remove(99)
        items = todo.load_data()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]['title'], 'Task X')


if __name__ == '__main__':
    unittest.main()
