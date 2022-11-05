import { structUtils } from "@yarnpkg/core"

export function cleanLocatorString(locatorString: string) {
  const locator = structUtils.parseLocator(locatorString)
  const range = structUtils.parseRange(locator.reference)

  if (range.protocol === 'patch:') {
    return structUtils.stringifyLocator({
      ...locator,
      reference: structUtils.makeRange({...range, params: null}),
    })
  }

  return locatorString
}
