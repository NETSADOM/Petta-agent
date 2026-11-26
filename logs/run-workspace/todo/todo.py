import json
import os
import sys

DATA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'todo.json')

def load_data():
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE, 'r') as f:
            return json.load(f)
    return []

def save_data(items):
    with open(DATA_FILE, 'w') as f:
        json.dump(items, f, indent=2)

def add(title):
    items = load_data()
    items.append({'title': title, 'done': False})
    save_data(items)
    print(f'Added: {title}')

def list_items():
    items = load_data()
    if not items:
        print('No items.')
        return
    for i, item in enumerate(items):
        mark = 'x' if item['done'] else ' '
        print(f"{i+1}. [{mark}] {item['title']}")

def done(index):
    items = load_data()
    if index < 1 or index > len(items):
        print(f'Invalid index: {index}')
        return
    items[index - 1]['done'] = True
    save_data(items)
    print(f"Marked done: {items[index - 1]['title']}")

def remove(index):
    items = load_data()
    if index < 1 or index > len(items):
        print(f'Invalid index: {index}')
        return
    removed = items.pop(index - 1)
    save_data(items)
    print(f"Removed: {removed['title']}")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: todo.py <add|list|done|remove> [args]')
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == 'add':
        if len(sys.argv) < 3:
            print('Usage: todo.py add <title>')
            sys.exit(1)
        add(sys.argv[2])
    elif cmd == 'list':
        list_items()
    elif cmd == 'done':
        if len(sys.argv) < 3:
            print('Usage: todo.py done <index>')
            sys.exit(1)
        done(int(sys.argv[2]))
    elif cmd == 'remove':
        if len(sys.argv) < 3:
            print('Usage: todo.py remove <index>')
            sys.exit(1)
        remove(int(sys.argv[2]))
    else:
        print(f'Unknown command: {cmd}')
        sys.exit(1)
