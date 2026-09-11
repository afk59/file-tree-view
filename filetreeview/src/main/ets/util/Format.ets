const BYTES_PER_UNIT: number = 1024;
const UNITS: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];

/**
 * Human-readable byte count for a tree row, e.g. `1.4 MB`.
 * Whole bytes stay whole (`842 B`); larger units get one decimal.
 */
export function formatSize(bytes: number): string {
  if (bytes < 0 || !Number.isFinite(bytes)) {
    return '';
  }
  let value: number = bytes;
  let unit: number = 0;
  while (value >= BYTES_PER_UNIT && unit < UNITS.length - 1) {
    value = value / BYTES_PER_UNIT;
    unit++;
  }
  if (unit === 0) {
    return `${value} ${UNITS[unit]}`;
  }
  // Round first, then re-check: 1048575 bytes is 1023.999 KB, which toFixed(1) turns into
  // "1024.0 KB". Promote the unit instead of printing a value above the loop's own threshold.
  let rounded: number = Number(value.toFixed(1));
  if (rounded >= BYTES_PER_UNIT && unit < UNITS.length - 1) {
    rounded = Number((value / BYTES_PER_UNIT).toFixed(1));
    unit++;
  }
  return `${rounded.toFixed(1)} ${UNITS[unit]}`;
}
