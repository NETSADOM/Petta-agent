#!/usr/bin/env python3
"""Simple command-line to-do application.

The application supports four commands:

  add "<description>"
      Add a new to‑do item.

  list
      List all items with their status.

  done <id>
      Mark the item with the given id as completed.

  remove <id>
      Remove the item with the given id.

All items are stored in a JSON file located next to this script
(`todo/todo.json`).  The JSON structure is a list of objects:

  {
      "id": 1,
      "description": "Buy milk",
      "done": false
  }

The id is an integer that increments for each new item.
"""

import argparse
import json
import os
import sys
from pathlib import Path

DATA_FILE = Path(__file__).with_name("todo.json")


def load_items():
    if not DATA_FILE.exists():
        return []
    with DATA_FILE.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_items(items):
    with DATA_FILE.open("w", encoding="utf-8") as f:
        json.dump(items, f, indent=2)


def next_id(items):
    if not items:
        return 1
    return max(item["id"] for item in items) + 1


def add_item(description):
    items = load_items()
    item = {"id": next_id(items), "description": description, "done": False}
    items.append(item)
    save_items(items)
    print(f"Added item {item['id']}: {description}")


def list_items():
    items = load_items()
    if not items:
        print("No items.")
        return
    for item in items:
        status = "✓" if item["done"] else "✗"
        print(f"{item['id']}. [{status}] {item['description']}")


def mark_done(item_id):
    items = load_items()
    for item in items:
        if item["id"] == item_id:
            item["done"] = True
            save_items(items)
            print(f"Marked item {item_id} as done.")
            return
    print(f"Item {item_id} not found.")


def remove_item(item_id):
    items = load_items()
    new_items = [item for item in items if item["id"] != item_id]
    if len(new_items) == len(items):
        print(f"Item {item_id} not found.")
        return
    save_items(new_items)
    print(f"Removed item {item_id}.")


def main():
    parser = argparse.ArgumentParser(description="Simple to‑do list.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="List all items")

    add = sub.add_parser("add", help="Add a new item")
    add.add_argument("description", help="Description of the item")

    done = sub.add_parser("done", help="Mark an item as done")
    done.add_argument("id", type=int, help="ID of the item")

    remove = sub.add_parser("remove", help="Remove an item")
    remove.add_argument("id", type=int, help="ID of the item")

    args = parser.parse_args()

    if args.cmd == "list":
        list_items()
    elif args.cmd == "add":
        add_item(args.description)
    elif args.cmd == "done":
        mark_done(args.id)
    elif args.cmd == "remove":
        remove_item(args.id)

if __name__ == "__main__":
    main()
