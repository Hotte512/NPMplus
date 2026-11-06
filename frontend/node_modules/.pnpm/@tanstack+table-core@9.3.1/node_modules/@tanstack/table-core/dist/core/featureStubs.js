//#region src/core/featureStubs.ts
/**
* Stubs for optional features, used by the core and by any feature or row
* model that reads another feature.
*
* Importing a feature's code from shared code would bundle that feature into
* every table that uses the shared code, registered or not. A stub instead
* calls a member the feature declares on its table, column, or row type and
* assigns when it is registered, and otherwise behaves as if the feature were
* absent. Members that only other features use are `_`-prefixed and marked
* `@internal`, such as `table._expandRows`.
*
* How code in this package reaches other code:
*
* - Its own feature: call the static function, or `callMemoOrStaticFn` to use
*   the feature's memoized API.
* - The core: import it. Every table bundles the core.
* - Another feature's state: read `table.atoms.<slice>?.get()`.
* - Another feature's APIs: call a stub from this file, adding one if needed.
* - A feature it requires, such as column resizing requiring column sizing:
*   import it.
*
* Features assign functions, internal ones included, with `assignTableAPIs` or
* `assignPrototypeAPIs`, and keep the `init*InstanceData` hooks for mutable
* per-instance state. The `import/no-restricted-paths` lint rule rejects value
* imports between feature folders outside an explicit list.
*
* Internal: not exported from any package entry point.
*/
/** Whether a column is visible; every column is without the feature. */
function getIsColumnVisible(column) {
	return column.getIsVisible?.() ?? true;
}
/** Visible leaf columns; all leaf columns without the feature. */
function getVisibleLeafColumns(table) {
	return table.getVisibleLeafColumns?.() ?? table.getAllLeafColumns();
}
/**
* A row's visible cells; all cells, in leaf column order, without the
* feature.
*/
function getVisibleCells(row) {
	return row.getVisibleCells?.() ?? row.getAllCells();
}
/** A row's visible cells by column id; all cells without the feature. */
function getVisibleCellsByColumnId(row) {
	return row.getVisibleCellsByColumnId?.() ?? row.getAllCellsByColumnId();
}
/**
* Orders leaf columns for display. The column ordering feature applies
* `columnOrder` and moves grouped columns. Without it, the grouping feature
* still moves grouped columns, and without either the order is unchanged.
*/
function orderLeafColumns(table, columns) {
	const orderedTable = table;
	const leafColumns = columns;
	return orderedTable.getOrderColumnsFn?.()(leafColumns) ?? orderedTable._orderGroupedColumns?.(leafColumns) ?? columns;
}
/**
* Orders items that each belong to a leaf column, such as visible leaf columns
* or a row's visible cells, with start-pinned items first and end-pinned items
* last. Without the feature, nothing is pinned and the order is unchanged.
*/
function orderByColumnPinning(table, items, getColumnId, getItemsByColumnId) {
	return table._orderByColumnPinning?.(items, getColumnId, getItemsByColumnId) ?? items;
}
/**
* Visible leaf columns in a pinning region. Without the feature, nothing is
* pinned: the start and end regions are empty, and the center region and the
* full list (`position` omitted) hold every visible leaf column.
*/
function getPinnedVisibleLeafColumns(table, position) {
	return table.getPinnedVisibleLeafColumns?.(position) ?? (position && position !== "center" ? [] : getVisibleLeafColumns(table));
}
/** The resolved global filter function, if the feature is registered. */
function getGlobalFilterFn(table) {
	return table.getGlobalFilterFn?.();
}
/** Whether a column takes part in global filtering; none do without the feature. */
function getCanGlobalFilter(column) {
	return column.getCanGlobalFilter?.() ?? false;
}
/**
* Lists expanded sub-rows inline below their parents. Without the feature no
* row is expanded, so the row model is returned as is.
*/
function expandRowModel(table, rowModel) {
	return table._expandRows?.(rowModel) ?? rowModel;
}
/**
* Whether every parent of a row is expanded. Without the feature no row is
* expanded, so only a top-level row qualifies.
*/
function getIsAllParentsExpanded(row) {
	return row.getIsAllParentsExpanded?.() ?? !row.parentId;
}
/** Resets expanded state if row expanding is registered. */
function autoResetExpanded(table) {
	table.autoResetExpanded?.();
}
/** Resets the page index if row pagination is registered. */
function autoResetPageIndex(table) {
	table.autoResetPageIndex?.();
}
/** Resets sorting if row sorting is registered. */
function autoResetSorting(table) {
	table.autoResetSorting?.();
}
/** Resets cell selection if cell selection is registered. */
function autoResetCellSelection(table) {
	table.autoResetCellSelection?.();
}
/**
* The aggregation executor `rowAggregationFeature` assigns to the table, or
* `undefined` when the feature is not registered.
*/
function getAggregateColumnValue(table) {
	return table._aggregateColumnValue;
}

//#endregion
export { autoResetCellSelection, autoResetExpanded, autoResetPageIndex, autoResetSorting, expandRowModel, getAggregateColumnValue, getCanGlobalFilter, getGlobalFilterFn, getIsAllParentsExpanded, getIsColumnVisible, getPinnedVisibleLeafColumns, getVisibleCells, getVisibleCellsByColumnId, getVisibleLeafColumns, orderByColumnPinning, orderLeafColumns };