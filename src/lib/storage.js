import { state } from '../state/state.js'

export function saveSelectedStore(storeId, storeName) {
  state.selectedStoreId = storeId
  state.selectedStoreName = storeName
  localStorage.setItem('selectedStoreId', storeId)
  localStorage.setItem('selectedStoreName', storeName)
}

export function loadSelectedStore() {
  state.selectedStoreId = localStorage.getItem('selectedStoreId')
  state.selectedStoreName = localStorage.getItem('selectedStoreName')
}
