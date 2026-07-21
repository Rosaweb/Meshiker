import os

def fix_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    replacements = {
        '\\u003d': '=',
        '\\u0027': "'",
        '\\u003c': '<',
        '\\u003e': '>',
        '\\u0026': '&',
        '\\u0022': '"',
        '\\u002b': '+',
        '\\u002d': '-',
        '\\u002f': '/',
        '\\u002a': '*',
        '\\u0025': '%',
        '\\u0021': '!',
        '\\u003f': '?',
        '\\u003a': ':',
        '\\u0028': '(',
        '\\u0029': ')',
        '\\u007b': '{',
        '\\u007d': '}',
        '\\u005b': '[',
        '\\u005d': ']',
        '\\u002c': ',',
        '\\u002e': '.',
        '\\u003b': ';',
        '\\u0023': '#',
        '\\u0024': '$',
    }

    for old, new in replacements.items():
        content = content.replace(old, new)

    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

fix_file(r'C:/Users/user/AndroidStudioProjects/Meshiker/lib/map/map_screen.dart')
