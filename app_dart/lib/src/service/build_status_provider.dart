// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:github/github.dart';
import 'package:meta/meta.dart';

import '../model/appengine/commit.dart';
import '../model/appengine/github_build_status_update.dart';
import '../model/appengine/stage.dart';
import '../model/appengine/task.dart';
import 'datastore.dart';

/// Function signature for a [BuildStatusService] provider.
typedef BuildStatusServiceProvider = BuildStatusService Function(DatastoreService datastoreService);

/// Branches that are used to calculate the tree status.
const Set<String> defaultBranches = <String>{'refs/heads/main', 'refs/heads/master'};

/// Class that calculates the current build status.
class BuildStatusService {
  const BuildStatusService(this.datastoreService);

  final DatastoreService datastoreService;

  /// Creates and returns a [DatastoreService] using [db] and [maxEntityGroups].
  static BuildStatusService defaultProvider(DatastoreService datastoreService) {
    return BuildStatusService(datastoreService);
  }

  @visibleForTesting
  static const int numberOfCommitsToReferenceForTreeStatus = 20;

  /// Calculates and returns the "overall" status of the Flutter build.
  ///
  /// This calculation operates by looking for the most recent success or
  /// failure for every (non-flaky) task in the manifest.
  ///
  /// Take the example build dashboard below:
  /// ✔ = passed, ✖ = failed, ☐ = new, ░ = in progress, s = skipped
  /// +---+---+---+---+
  /// | A | B | C | D |
  /// +---+---+---+---+
  /// | ✔ | ☐ | ░ | s |
  /// +---+---+---+---+
  /// | ✔ | ░ | ✔ | ✖ |
  /// +---+---+---+---+
  /// | ✔ | ✖ | ✔ | ✔ |
  /// +---+---+---+---+
  /// This build will fail because of Task B only. Task D is not included in
  /// the latest commit status, so it does not impact the build status.
  /// Task B fails because its last known status was to be failing, even though
  /// there is currently a newer version that is in progress.
  ///
  /// Tree status is only for [defaultBranches].
  Future<BuildStatus?> calculateCumulativeStatus(RepositorySlug slug) async {
    final List<CommitStatus> statuses = await retrieveCommitStatus(
      limit: numberOfCommitsToReferenceForTreeStatus,
      slug: slug,
    ).toList();
    if (statuses.isEmpty) {
      return BuildStatus.failure();
    }

    final Map<String, bool> tasksInProgress = _findTasksRelevantToLatestStatus(statuses);
    if (tasksInProgress.isEmpty) {
      return BuildStatus.failure();
    }

    final List<String> failedTasks = <String>[];
    for (CommitStatus status in statuses) {
      for (Stage stage in status.stages) {
        for (Task task in stage.tasks) {
          /// If a task [isRelevantToLatestStatus] but has not run yet, we look
          /// for a previous run of the task from the previous commit.
          final bool isRelevantToLatestStatus = tasksInProgress.containsKey(task.name);

          /// Tasks that are not relevant to the latest status will have a
          /// null value in the map.
          final bool taskInProgress = tasksInProgress[task.name] ?? true;

          if (isRelevantToLatestStatus && taskInProgress) {
            if (task.isFlaky! || _isSuccessful(task)) {
              /// This task no longer needs to be checked to see if it causing
              /// the build status to fail.
              tasksInProgress[task.name!] = false;
            } else if (_isFailed(task) || _isRerunning(task)) {
              failedTasks.add(task.name!);

              /// This task no longer needs to be checked to see if its causing
              /// the build status to fail since its been
              /// added to the failedTasks list.
              tasksInProgress[task.name!] = false;
            }
          }
        }
      }
    }
    return failedTasks.isNotEmpty ? BuildStatus.failure(failedTasks) : BuildStatus.success();
  }

  /// Creates a map of the tasks that need to be checked for the build status.
  ///
  /// This is based on the most recent [CommitStatus] and all of its tasks.
  Map<String, bool> _findTasksRelevantToLatestStatus(List<CommitStatus> statuses) {
    final Map<String, bool> tasks = <String, bool>{};

    for (Stage stage in statuses.first.stages) {
      for (Task task in stage.tasks) {
        tasks[task.name!] = true;
      }
    }

    return tasks;
  }

  /// Retrieves the comprehensive status of every task that runs per commit.
  ///
  /// The returned stream will be ordered by most recent commit first, then
  /// the next newest, and so on.
  Stream<CommitStatus> retrieveCommitStatus({
    required int limit,
    int? timestamp,
    String? branch,
    required RepositorySlug slug,
  }) async* {
    await for (Commit commit in datastoreService.queryRecentCommits(
      limit: limit,
      timestamp: timestamp,
      branch: branch,
      slug: slug,
    )) {
      final List<Stage> stages = await datastoreService.queryTasksGroupedByStage(commit);
      yield CommitStatus(commit, stages);
    }
  }

  bool _isFailed(Task task) {
    return task.status == Task.statusFailed ||
        task.status == Task.statusInfraFailure ||
        task.status == Task.statusCancelled;
  }

  bool _isSuccessful(Task task) {
    return task.status == Task.statusSucceeded;
  }

  bool _isRerunning(Task task) {
    return task.attempts! > 1 && (task.status == Task.statusInProgress || task.status == Task.statusNew);
  }
}

/// Class that holds the status for all tasks corresponding to a particular
/// commit.
///
/// Tasks may still be running, and thus their status is subject to change.
/// Put another way, this class holds information that is a snapshot in time.
@immutable
class CommitStatus {
  /// Creates a new [CommitStatus].
  const CommitStatus(this.commit, this.stages);

  /// The commit against which all the tasks in [stages] are run.
  final Commit commit;

  /// The partitioned stages, each of which holds a bucket of tasks that
  /// belong in the stage.
  final List<Stage> stages;
}

@immutable
class BuildStatus {
  const BuildStatus._(this.value, [this.failedTasks = const <String>[]])
      : assert(value == GithubBuildStatusUpdate.statusSuccess || value == GithubBuildStatusUpdate.statusFailure);
  factory BuildStatus.success() => const BuildStatus._(GithubBuildStatusUpdate.statusSuccess);
  factory BuildStatus.failure([List<String> failedTasks = const <String>[]]) =>
      BuildStatus._(GithubBuildStatusUpdate.statusFailure, failedTasks);

  final String value;
  final List<String> failedTasks;

  bool get succeeded {
    return value == GithubBuildStatusUpdate.statusSuccess;
  }

  String get githubStatus => value;

  @override
  int get hashCode {
    int hash = 17;
    hash = hash * 31 + value.hashCode;
    hash = hash * 31 + failedTasks.hashCode;
    return hash;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is BuildStatus) {
      if (value != other.value) {
        return false;
      }
      if (other.failedTasks.length != failedTasks.length) {
        return false;
      }
      for (int i = 0; i < failedTasks.length; ++i) {
        if (failedTasks[i] != other.failedTasks[i]) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  @override
  String toString() => '$value $failedTasks';
}
