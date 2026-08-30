import os
import pandas as pd

base = r'D:\Nandhu\dead reckoning\idr-project\data'
# Try to find an S file
for root, dirs, files in os.walk(base):
    for f in files:
        if 'S-' in f and f.endswith('.csv'):
            fpath = os.path.join(root, f)
            try:
                df = pd.read_csv(fpath, nrows=2, encoding='latin-1')
                basename = os.path.basename(fpath)
                print(f'File: {basename}')
                print('Columns:', list(df.columns))
                # Try to find a time column
                for c in df.columns:
                    c_lower = c.lower()
                    if 'time' in c_lower or 'since' in c_lower or 'Time' in c:
                        print(f'  Time column: {c}')
                print()
            except Exception as e:
                print(f'Error with {fpath}: {e}')
                print()
"