# To-Do App

A small command-line to-do list stored in `todo.json` next to the script.

## Usage


python3 todo.py add "Item text"   # add a new item
python3 todo.py list              # list all items
python3 todo.py done N            # mark item N as done
python3 todo.py remove N          # remove item N


## Tests

Run the unit tests with:


cd todo && python3 -m unittest test_todo -v


All 7 tests pass.
