# Install python-dotenv

The `dotenv` utility is used to allow you to save your naming decisions, so that you can walk away and pick things up later. It's completely optional, but probably worthwhile to keep track of your naming decisions.

Install python-dotenv:

    python -m pip install python-dotenv

This installs the `dotenv` commandline utility, which is what you'll use to save your decisions. You should use it anywhere you see an `export VAR=<your-value>`. Translated the export instead to `export "$(dotenv set VAR <your-value>)"`, which will both save the `VAR` to your `.env` file and export it in the current shell.

If you walk away, close your shell, etc., you'll want to load the variables from the `.env` file.
