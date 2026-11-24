import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

/// Generic Supabase configuration template
/// Replace YOUR_ and YOUR_ with your actual values
class SupabaseConfig {
  static const String supabaseUrl = 'https://uiuqdjzgedvcsnubnzhm.supabase.co';
  static const String anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVpdXFkanpnZWR2Y3NudWJuemhtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ3NDE4NjAsImV4cCI6MjEwMDMxNzg2MH0.F8_NrsQjCU8LlNWJT0drGywjtxMN8Sq_buqKSmLc_88';

  static Future<void> initialize() async {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: anonKey,
      debug: kDebugMode,
    );
  }

  static SupabaseClient get client => Supabase.instance.client;
  static GoTrueClient get auth => client.auth;
}

/// Generic database service for CRUD operations
class SupabaseService {
  /// Calls the Supabase Edge Function `sync_user_password` to create/update a
  /// user's password in Supabase Auth.
  ///
  /// Authorization rules are enforced server-side:
  /// - the logged in user can update their own password
  /// - admin users (tipousuario == 'A') can update any user's password
  static Future<Map<String, dynamic>> syncUserPasswordInAuth({
    required String email,
    required String password,
  }) async {
    try {
      final session = SupabaseConfig.auth.currentSession;
      final accessToken = session?.accessToken;
      if (accessToken == null || accessToken.isEmpty) {
        return {
          'ok': false,
          'error': 'not_authenticated',
          'hint': 'Missing Supabase session access token',
        };
      }

      final res = await SupabaseConfig.client.functions.invoke(
        'sync_user_password',
        body: {
          'email': email.trim().toLowerCase(),
          'password': password,
        },
        headers: {
          // Be explicit; on Web the auth header is the #1 cause of 401/403.
          'Authorization': 'Bearer $accessToken',
          'apikey': SupabaseConfig.anonKey,
        },
      );

      final data = res.data;
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      return {'ok': false, 'error': 'unexpected_response', 'data': data};
    } catch (e) {
      // On Flutter Web, missing Edge Function / CORS issues often surface as
      // `ClientException: Failed to fetch`.
      debugPrint('syncUserPasswordInAuth failed: $e');
      final msg = e.toString();
      if (msg.contains('Failed to fetch')) {
        return {
          'ok': false,
          'error': 'failed_to_fetch',
          'hint': 'Edge Function not deployed or blocked by CORS/network',
        };
      }

      if (msg.contains('403') || msg.contains('status: 403')) {
        return {
          'ok': false,
          'error': 'forbidden',
          'hint': 'Edge Function rejected the request (403). Check permissions/JWT and function deploy.',
          'details': msg,
        };
      }
      return {'ok': false, 'error': 'exception', 'details': msg};
    }
  }

  /// Select multiple records from a table
  static Future<List<Map<String, dynamic>>> select(
    String table, {
    String? select,
    Map<String, dynamic>? filters,
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    try {
      dynamic query = SupabaseConfig.client.from(table).select(select ?? '*');

      // Apply filters
      if (filters != null) {
        for (final entry in filters.entries) {
          query = query.eq(entry.key, entry.value);
        }
      }

      // Apply ordering
      if (orderBy != null) {
        query = query.order(orderBy, ascending: ascending);
      }

      // Apply limit
      if (limit != null) {
        query = query.limit(limit);
      }

      return await query;
    } catch (e) {
      throw _handleDatabaseError('select', table, e);
    }
  }

  /// Select a single record from a table
  static Future<Map<String, dynamic>?> selectSingle(
    String table, {
    String? select,
    required Map<String, dynamic> filters,
  }) async {
    try {
      dynamic query = SupabaseConfig.client.from(table).select(select ?? '*');

      for (final entry in filters.entries) {
        query = query.eq(entry.key, entry.value);
      }

      return await query.maybeSingle();
    } catch (e) {
      throw _handleDatabaseError('selectSingle', table, e);
    }
  }

  /// Insert a record into a table
  static Future<List<Map<String, dynamic>>> insert(
    String table,
    Map<String, dynamic> data,
  ) async {
    try {
      return await SupabaseConfig.client.from(table).insert(data).select();
    } catch (e) {
      throw _handleDatabaseError('insert', table, e);
    }
  }

  /// Insert multiple records into a table
  static Future<List<Map<String, dynamic>>> insertMultiple(
    String table,
    List<Map<String, dynamic>> data,
  ) async {
    try {
      return await SupabaseConfig.client.from(table).insert(data).select();
    } catch (e) {
      throw _handleDatabaseError('insertMultiple', table, e);
    }
  }

  /// Update records in a table
  static Future<List<Map<String, dynamic>>> update(
    String table,
    Map<String, dynamic> data, {
    required Map<String, dynamic> filters,
  }) async {
    try {
      dynamic query = SupabaseConfig.client.from(table).update(data);

      for (final entry in filters.entries) {
        query = query.eq(entry.key, entry.value);
      }

      return await query.select();
    } catch (e) {
      throw _handleDatabaseError('update', table, e);
    }
  }

  /// Delete records from a table
  static Future<void> delete(
    String table, {
    required Map<String, dynamic> filters,
  }) async {
    try {
      dynamic query = SupabaseConfig.client.from(table).delete();

      for (final entry in filters.entries) {
        query = query.eq(entry.key, entry.value);
      }

      await query;
    } catch (e) {
      throw _handleDatabaseError('delete', table, e);
    }
  }

  /// Get direct table reference for complex queries
  static SupabaseQueryBuilder from(String table) =>
      SupabaseConfig.client.from(table);

  /// Handle database errors
  static String _handleDatabaseError(
    String operation,
    String table,
    dynamic error,
  ) {
    if (error is PostgrestException) {
      return 'Failed to $operation from $table: ${error.message}';
    } else {
      return 'Failed to $operation from $table: ${error.toString()}';
    }
  }
}
