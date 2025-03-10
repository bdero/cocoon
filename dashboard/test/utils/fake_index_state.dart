// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter_dashboard/logic/brooks.dart';
import 'package:flutter_dashboard/service/google_authentication.dart';
import 'package:flutter_dashboard/state/index.dart';

import 'mocks.dart';

class FakeIndexState extends ChangeNotifier implements IndexState {
  FakeIndexState({GoogleSignInService? authService}) : authService = authService ?? MockGoogleSignInService();

  @override
  final GoogleSignInService authService;

  @override
  final ErrorSink errors = ErrorSink();
}
