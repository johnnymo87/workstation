import type { LogRecord } from "./index"

export function consoleSink(record: LogRecord) {
  console.log(JSON.stringify(record))
}
