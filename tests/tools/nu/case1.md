# Inventory table with multi-word values

## Prompt

Create an inventory table with these columns: id, product, price, stock.

Use this data:
- 101, Widget A, 25.50, 100
- 102, Gadget B, 15.00, 50
- 103, Tool C, 42.99, 25

Add a computed column `total_value` (price * stock). Return only product and
total_value, sorted by total_value descending.

## Expected

The nu tool output should be valid nuon that parses to a 3-row table:

| product  | total_value |
|----------|-------------|
| Widget A | 2550.0      |
| Tool C   | 1074.75     |
| Gadget B | 750.0       |

## Evaluation

1. Output is valid nuon (can be parsed by `from nuon`)
2. Result is a list of 3 records with `product` and `total_value` columns
3. Multi-word value "Widget A" is preserved (not split or unquoted)
4. Row order is descending by total_value
5. Values are numerically correct
