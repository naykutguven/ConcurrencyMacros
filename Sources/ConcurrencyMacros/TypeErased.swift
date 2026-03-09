//
//  TypeErased.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation

/// Type-erased wrapper to allow storing values of any type in a homogeneous collection.
/// This is used for storing property values in the thread-safe wrapper without exposing their types.
public struct TypeErased<T> {
  let value: T?

  public init(value: T? = nil) {
    self.value = value
  }
}
