import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/user_model.dart';
import '../models/message_model.dart';
import '../models/friend_model.dart';

class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Get current user ID
  String? get currentUserId => _auth.currentUser?.uid;

  // Search users by email
  Stream<List<UserModel>> searchUsers(String query) {
    if (query.isEmpty) {
      return Stream.value([]);
    }

    return _firestore
        .collection('User')
        .where('email', isGreaterThanOrEqualTo: query)
        .where('email', isLessThanOrEqualTo: '$query\uf8ff')
        .where('uid', isNotEqualTo: currentUserId)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => UserModel.fromFirestore(doc))
            .toList());
  }

  // Get all users except current user
  Stream<List<UserModel>> get allUsersStream {
    return _firestore
        .collection('User')
        .where('uid', isNotEqualTo: currentUserId)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => UserModel.fromFirestore(doc))
            .toList());
  }

  // Get user by UID
  Stream<UserModel?> getUserStream(String uid) {
    return _firestore.collection('User').doc(uid).snapshots().map((doc) {
      if (doc.exists) {
        return UserModel.fromFirestore(doc);
      }
      return null;
    });
  }

  // Get or create chat room ID (consistent between two users)
  String getChatRoomId(String userId1, String userId2) {
    final ids = [userId1, userId2]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  // Send message
  Future<void> sendMessage({
    required String receiverId,
    required String message,
    MessageType type = MessageType.text,
  }) async {
    if (currentUserId == null) {
      throw Exception('User not authenticated');
    }

    final chatRoomId = getChatRoomId(currentUserId!, receiverId);

    final messageData = MessageModel(
      id: '',
      senderId: currentUserId!,
      receiverId: receiverId,
      message: message,
      timestamp: DateTime.now(),
      type: type,
    ).toMap();

    try {
      // Add to messages subcollection
      await _firestore
          .collection('chatRooms')
          .doc(chatRoomId)
          .collection('messages')
          .add(messageData);

      // Update last message in chat room
      await _firestore.collection('chatRooms').doc(chatRoomId).set({
        'participants': [currentUserId, receiverId],
        'lastMessage': message,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': currentUserId,
      }, SetOptions(merge: true));
    } catch (e) {
      throw Exception('Failed to send message: $e');
    }
  }

  // Get messages stream with a user
  Stream<List<MessageModel>> getMessagesStream(String otherUserId) {
    if (currentUserId == null) {
      return Stream.value([]);
    }

    final chatRoomId = getChatRoomId(currentUserId!, otherUserId);

    return _firestore
        .collection('chatRooms')
        .doc(chatRoomId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => MessageModel.fromFirestore(doc))
            .toList());
  }

  // Get chat rooms for current user
  Stream<List<ChatRoomInfo>> getChatRoomsStream() {
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return _firestore
        .collection('chatRooms')
        .where('participants', arrayContains: currentUserId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots()
        .asyncMap((snapshot) async {
      final chatRooms = <ChatRoomInfo>[];

      for (var doc in snapshot.docs) {
        final data = doc.data();
        final participants = List<String>.from(data['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != currentUserId,
          orElse: () => '',
        );

        if (otherUserId.isNotEmpty) {
          final userDoc = await _firestore.collection('User').doc(otherUserId).get();
          UserModel? otherUser;
          if (userDoc.exists) {
            otherUser = UserModel.fromFirestore(userDoc);
          }

          chatRooms.add(ChatRoomInfo(
            chatRoomId: doc.id,
            otherUser: otherUser,
            lastMessage: data['lastMessage'] ?? '',
            lastMessageTime: (data['lastMessageTime'] as Timestamp?)?.toDate(),
            lastMessageSenderId: data['lastMessageSenderId'],
          ));
        }
      }

      return chatRooms;
    });
  }

  // Mark messages as read
  Future<void> markMessagesAsRead(String otherUserId) async {
    if (currentUserId == null) return;

    final chatRoomId = getChatRoomId(currentUserId!, otherUserId);

    final snapshot = await _firestore
        .collection('chatRooms')
        .doc(chatRoomId)
        .collection('messages')
        .where('receiverId', isEqualTo: currentUserId)
        .where('isRead', isEqualTo: false)
        .get();

    final batch = _firestore.batch();
    for (var doc in snapshot.docs) {
      batch.update(doc.reference, {'isRead': true});
    }
    await batch.commit();
  }

  // Get unread message count for a chat
  Stream<int> getUnreadCountStream(String otherUserId) {
    if (currentUserId == null) {
      return Stream.value(0);
    }

    final chatRoomId = getChatRoomId(currentUserId!, otherUserId);

    return _firestore
        .collection('chatRooms')
        .doc(chatRoomId)
        .collection('messages')
        .where('receiverId', isEqualTo: currentUserId)
        .where('isRead', isEqualTo: false)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  // Add friend by email (works with any Firebase Auth user)
  Future<bool> addFriend(String friendEmail) async {
    if (currentUserId == null) return false;

    final email = friendEmail.toLowerCase().trim();

    // Validate email format
    if (!email.contains('@') || !email.contains('.')) {
      throw Exception('Please enter a valid email address');
    }

    // Check if trying to add yourself
    final currentUserDoc = await _firestore.collection('User').doc(currentUserId).get();
    final currentUserEmail = currentUserDoc.data()?['email']?.toString().toLowerCase() ?? '';

    if (email == currentUserEmail) {
      throw Exception('You cannot add yourself as a friend');
    }

    // Search for user in Firestore User collection by email
    final userSnapshot = await _firestore
        .collection('User')
        .where('email', isEqualTo: email)
        .limit(1)
        .get();

    String friendId;

    if (userSnapshot.docs.isEmpty) {
      // User doesn't exist in Firestore yet - create a minimal profile
      friendId = _generateUserIdFromEmail(email);

      // Create a placeholder user document
      await _firestore.collection('User').doc(friendId).set({
        'email': email,
        'displayName': email.split('@').first,
        'photoUrl': null,
        'isOnline': false,
        'lastSeen': null,
        'createdAt': FieldValue.serverTimestamp(),
        'isPlaceholder': true,
      }, SetOptions(merge: true));
    } else {
      friendId = userSnapshot.docs.first.id;
    }

    // Check if already friends
    final friendRef = _firestore.collection('friends').doc(currentUserId);
    final friendData = await friendRef.get();

    if (friendData.exists) {
      final friends = (friendData.data()?['friends'] as List<dynamic>?) ?? [];
      if (friends.contains(friendId)) {
        throw Exception('This user is already in your friend list');
      }
    }

    // Add friend to current user's friend list (mutual friendship - automatic)
    await friendRef.set({
      'friends': FieldValue.arrayUnion([friendId]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // Also add current user to friend's list (mutual friendship)
    await _firestore.collection('friends').doc(friendId).set({
      'friends': FieldValue.arrayUnion([currentUserId!]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    return true;
  }

  // Generate a consistent user ID from email for placeholder users
  String _generateUserIdFromEmail(String email) {
    return 'user_${email.hashCode.abs().toString()}';
  }

  // Get friends stream
  Stream<List<FriendModel>> getFriendsStream() {
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return _firestore.collection('friends').doc(currentUserId).snapshots().asyncMap((snapshot) async {
      if (!snapshot.exists) {
        return [];
      }

      final data = snapshot.data();
      final friendIds = List<String>.from(data?['friends'] ?? []);

      if (friendIds.isEmpty) {
        return [];
      }

      final friends = <FriendModel>[];
      for (var friendId in friendIds) {
        final friendDoc = await _firestore.collection('User').doc(friendId).get();
        if (friendDoc.exists) {
          friends.add(FriendModel.fromFirestore(friendDoc));
        }
      }

      return friends;
    });
  }

  // Remove friend
  Future<void> removeFriend(String friendId) async {
    if (currentUserId == null) return;

    // Remove from current user's friend list
    await _firestore.collection('friends').doc(currentUserId).update({
      'friends': FieldValue.arrayRemove([friendId]),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // Remove from friend's list (mutual friendship)
    await _firestore.collection('friends').doc(friendId).update({
      'friends': FieldValue.arrayRemove([currentUserId]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Search user by email
  Future<UserModel?> searchUserByEmail(String email) async {
    final userSnapshot = await _firestore
        .collection('User')
        .where('email', isEqualTo: email.toLowerCase())
        .limit(1)
        .get();

    if (userSnapshot.docs.isEmpty) {
      return null;
    }

    return UserModel.fromFirestore(userSnapshot.docs.first);
  }
}

class ChatRoomInfo {
  final String chatRoomId;
  final UserModel? otherUser;
  final String lastMessage;
  final DateTime? lastMessageTime;
  final String? lastMessageSenderId;

  ChatRoomInfo({
    required this.chatRoomId,
    this.otherUser,
    required this.lastMessage,
    this.lastMessageTime,
    this.lastMessageSenderId,
  });
}
