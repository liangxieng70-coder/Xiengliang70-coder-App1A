import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Get current user stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Check if user is authenticated
  bool get isAuthenticated => currentUser != null;

  // Sign in with email and password
  Future<UserCredential?> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      
      // Update user's online status
      await _firestore.collection('User').doc(currentUser!.uid).update({
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
      });
      
      return credential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    }
  }

  // Register with email and password
  Future<UserCredential?> registerWithEmailAndPassword({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      final userId = credential.user!.uid;
      final emailLower = email.toLowerCase().trim();

      // Check if there's a placeholder user document for this email
      final placeholderSnapshot = await _firestore
          .collection('User')
          .where('email', isEqualTo: emailLower)
          .where('isPlaceholder', isEqualTo: true)
          .limit(1)
          .get();

      if (placeholderSnapshot.docs.isNotEmpty) {
        // Merge existing placeholder document with real user data
        final placeholderDoc = placeholderSnapshot.docs.first;
        await _firestore.collection('User').doc(placeholderDoc.id).update({
          'uid': userId,
          'displayName': displayName,
          'createdAt': DateTime.now(),
          'isOnline': true,
          'isPlaceholder': false,
          'lastSeen': FieldValue.serverTimestamp(),
        });
        
        // If placeholder ID is different from new auth UID, update friends references
        if (placeholderDoc.id != userId) {
          // Update friends collection to use new UID
          await _migratePlaceholderFriends(placeholderDoc.id, userId);
          
          // Delete old placeholder document
          await _firestore.collection('User').doc(placeholderDoc.id).delete();
        }
      } else {
        // Create new user document
        final userModel = UserModel(
          uid: userId,
          email: emailLower,
          displayName: displayName,
          createdAt: DateTime.now(),
          isOnline: true,
        );

        await _firestore.collection('User').doc(userId).set(
          userModel.toMap(),
        );
      }

      return credential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    }
  }

  // Migrate friend references from placeholder ID to real user ID
  Future<void> _migratePlaceholderFriends(String oldId, String newId) async {
    // Get all friend lists that contain the old ID
    final friendsSnapshot = await _firestore.collection('friends').get();

    final batch = _firestore.batch();
    for (var doc in friendsSnapshot.docs) {
      final data = doc.data();
      final friends = List<dynamic>.from(data['friends'] ?? []);

      if (friends.contains(oldId)) {
        batch.update(doc.reference, {
          'friends': FieldValue.arrayRemove([oldId]),
        });
        batch.update(doc.reference, {
          'friends': FieldValue.arrayUnion([newId]),
        });
      }
    }
    await batch.commit();
    
    // Copy friends list from old ID to new ID
    final oldFriendsDoc = await _firestore.collection('friends').doc(oldId).get();
    if (oldFriendsDoc.exists) {
      final friends = oldFriendsDoc.data()?['friends'] as List<dynamic>? ?? [];
      await _firestore.collection('friends').doc(newId).set({
        'friends': friends,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await _firestore.collection('friends').doc(oldId).delete();
    }
  }

  // Sign out
  Future<void> signOut() async {
    try {
      // Update user's offline status before signing out
      if (currentUser != null) {
        await _firestore.collection('User').doc(currentUser!.uid).update({
          'isOnline': false,
          'lastSeen': FieldValue.serverTimestamp(),
        });
      }
      await _auth.signOut();
    } catch (e) {
      throw Exception('Failed to sign out: $e');
    }
  }

  // Get user data from Firestore
  Future<UserModel?> getUserData(String uid) async {
    try {
      final doc = await _firestore.collection('User').doc(uid).get();
      if (doc.exists) {
        return UserModel.fromFirestore(doc);
      }
      return null;
    } catch (e) {
      throw Exception('Failed to get user data: $e');
    }
  }

  // Get current user data
  Future<UserModel?> getCurrentUserData() async {
    if (currentUser == null) return null;
    return getUserData(currentUser!.uid);
  }

  // Stream of current user data
  Stream<UserModel?> get currentUserStream {
    if (currentUser == null) {
      return Stream.value(null);
    }
    return _firestore.collection('User').doc(currentUser!.uid).snapshots().map(
      (doc) {
        if (doc.exists) {
          return UserModel.fromFirestore(doc);
        }
        return null;
      },
    );
  }

  // Update user's online status
  Future<void> updateUserStatus(bool isOnline) async {
    if (currentUser == null) return;
    
    await _firestore.collection('User').doc(currentUser!.uid).update({
      'isOnline': isOnline,
      'lastSeen': FieldValue.serverTimestamp(),
    });
  }

  // Password reset
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    }
  }

  // Handle Firebase Auth exceptions
  String _handleAuthException(FirebaseAuthException e) {
    switch (e.code) {
      case 'weak-password':
        return 'The password provided is too weak.';
      case 'email-already-in-use':
        return 'An account already exists for that email.';
      case 'user-not-found':
        return 'No user found for that email.';
      case 'wrong-password':
        return 'Wrong password provided.';
      case 'invalid-email':
        return 'The email address is not valid.';
      case 'user-disabled':
        return 'This user account has been disabled.';
      case 'too-many-requests':
        return 'Too many requests. Please try again later.';
      default:
        return e.message ?? 'An authentication error occurred.';
    }
  }
}
